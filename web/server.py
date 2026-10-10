#!/usr/bin/env python3
"""Local-only DanceFrame editor. Python standard library + FFmpeg."""
import argparse
import json
import math
import mimetypes
import re
import shutil
import subprocess
import threading
import uuid
from fractions import Fraction
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse, quote

ROOT = Path(__file__).resolve().parent
WORK = ROOT / 'work'
EXPORTS = ROOT / 'exports'
MEDIA = {}
JOBS = {}
LOCK = threading.Lock()


def probe(path):
    data = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(path)]))
    stream = next((s for s in data['streams'] if s['codec_type'] == 'video'), None)
    if not stream:
        raise ValueError('This file has no video stream.')
    w, h = stream['width'], stream['height']
    rotation = next((s.get('rotation', 0) for s in stream.get('side_data_list', []) if 'rotation' in s), 0)
    if abs(round(rotation)) % 180 == 90:
        w, h = h, w
    if w < h:
        raise ValueError('Please choose a landscape video.')
    fps = float(Fraction(stream.get('avg_frame_rate', '30/1') or '30/1'))
    duration = float(data['format'].get('duration', stream.get('duration', 0)))
    if not math.isfinite(duration) or duration <= 0 or not 0 < fps <= 240:
        raise ValueError('Could not determine a supported duration / frame rate.')
    return dict(width=w, height=h, fps=fps, duration=duration, cropWidth=int(h * 9 / 16) // 2 * 2, cropHeight=h // 2 * 2)


def validate_points(raw, meta):
    if not isinstance(raw, list) or not 1 <= len(raw) <= 10000:
        raise ValueError('Add at least one tracking point (maximum 10,000).')
    result = []
    for point in raw:
        t, x = float(point['t']), float(point['x'])
        if not math.isfinite(t) or not math.isfinite(x) or not 0 <= t <= meta['duration'] or not 0 <= x <= 1:
            raise ValueError('Invalid tracking point.')
        result.append(dict(t=t, x=x))
    result.sort(key=lambda p: p['t'])
    if any(b['t'] - a['t'] < 0.000001 for a, b in zip(result, result[1:])):
        raise ValueError('Tracking points must have distinct times.')
    return result


def commands(points, width, mode):
    # The crop filter evaluates these expressions at each source frame's timestamp.
    rows = [f"0 crop@follow x '{points[0]['x'] * width:.9f}';"]
    for a, b in zip(points, points[1:]):
        u = f"((t-{a['t']:.9f})/{b['t']-a['t']:.9f})"
        curve = u if mode == 'linear' else f'({u}*{u}*(3-2*{u}))'
        expr = f"{a['x']*width:.9f}+({(b['x']-a['x'])*width:.9f})*{curve}"
        rows.append(f"{a['t']:.9f} crop@follow x '{expr}';")
    rows.append(f"{points[-1]['t']:.9f} crop@follow x '{points[-1]['x']*width:.9f}';")
    return '\n'.join(rows)


def validate_trim(raw, meta):
    if raw is None:
        return {'start': 0.0, 'end': meta['duration']}
    start, end = float(raw['start']), float(raw['end'])
    if not math.isfinite(start) or not math.isfinite(end) or not 0 <= start < end <= meta['duration'] or end-start < 1/meta['fps']:
        raise ValueError('Trim must be inside the video and at least one frame long.')
    return {'start': start, 'end': end}


def export_job(job_id, meta, points, mode, size, trim=None):
    job = JOBS[job_id]
    trim = validate_trim(trim, meta)
    length = trim['end'] - trim['start']
    jobdir = WORK / job_id
    jobdir.mkdir()
    (jobdir / 'motion.txt').write_text(commands(points, meta['width']-meta['cropWidth'], mode))
    output = EXPORTS / f"{Path(meta['name']).stem}-vertical-{job_id[:8]}.mp4"
    scale = '1080:1920' if size == '1080' else '720:1280'
    vf = f"setpts=PTS-STARTPTS,sendcmd=f=motion.txt,crop@follow={meta['cropWidth']}:{meta['cropHeight']}:0:0:exact=1,trim=start={trim['start']:.9f}:end={trim['end']:.9f},setpts=PTS-STARTPTS,scale={scale}:flags=lanczos,setsar=1"
    args = ['ffmpeg', '-hide_banner', '-y', '-i', meta['path'], '-map', '0:v:0', '-map', '0:a:0?', '-vf', vf, '-c:v', 'libx264', '-preset', 'fast', '-crf', '18', '-pix_fmt', 'yuv420p', '-af', f"atrim=start={trim['start']:.9f}:end={trim['end']:.9f},asetpts=PTS-STARTPTS", '-t', str(length), '-c:a', 'aac', '-b:a', '192k', '-movflags', '+faststart', '-progress', 'pipe:1', '-nostats', str(output)]
    try:
        with (jobdir / 'ffmpeg.log').open('w') as log:
            process = subprocess.Popen(args, cwd=jobdir, stdout=subprocess.PIPE, stderr=log, text=True)
            job['process'] = process
            if job.get('cancelled'):
                process.terminate()
            for line in process.stdout:
                if line.startswith('out_time_us='):
                    try:
                        job['progress'] = min(0.99, int(line.split('=')[1]) / 1e6 / length)
                    except ValueError:
                        pass
            code = process.wait()
            process.stdout.close()
        if job.get('cancelled'):
            job['status'] = 'cancelled'
            output.unlink(missing_ok=True)
        elif code:
            raise RuntimeError((jobdir / 'ffmpeg.log').read_text()[-2500:])
        else:
            job.update(status='done', progress=1, url='/exports/' + quote(output.name), filename=output.name)
    except Exception as exc:
        job.update(status='error', error=str(exc))
        output.unlink(missing_ok=True)
    finally:
        job.pop('process', None)


class Handler(BaseHTTPRequestHandler):
    def json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        # Reject cross-origin writes and DNS rebinding; no permissive CORS.
        expected = f'http://{self.headers.get("Host", "")}'
        if self.headers.get('Origin', expected) != expected or self.headers.get('Host') not in {f'127.0.0.1:{self.server.server_port}', f'localhost:{self.server.server_port}'}:
            return self.json({'error': 'Local requests only.'}, 403)
        try:
            length = int(self.headers.get('Content-Length', 0))
            if self.path == '/api/upload':
                if not 0 < length <= 100 * 1024**3:
                    raise ValueError('Choose a video smaller than 100 GB.')
                media_id = uuid.uuid4().hex
                path = WORK / (media_id + '.video')
                try:
                    with path.open('wb') as out:
                        remaining = length
                        while remaining:
                            chunk = self.rfile.read(min(1024 * 1024, remaining))
                            if not chunk:
                                raise ValueError('Upload interrupted.')
                            out.write(chunk)
                            remaining -= len(chunk)
                    meta = probe(path)
                except Exception:
                    path.unlink(missing_ok=True)
                    raise
                from urllib.parse import unquote
                name = Path(unquote(self.headers.get('X-Filename', 'video.mp4'))).name
                meta.update(id=media_id, name=name, path=str(path), url='/media/' + media_id)
                MEDIA[media_id] = meta
                return self.json({k: v for k, v in meta.items() if k != 'path'})
            if length > 2 * 1024 * 1024:
                raise ValueError('Request too large.')
            data = json.loads(self.rfile.read(length))
            if self.path == '/api/export':
                meta = MEDIA[data['id']]
                points = validate_points(data['points'], meta)
                trim = validate_trim(data.get('trim'), meta)
                mode = data.get('mode', 'smooth')
                size = data.get('size', '1080')
                if mode not in ('smooth', 'linear') or size not in ('720', '1080'):
                    raise ValueError('Invalid export settings.')
                with LOCK:
                    if any(j['status'] == 'running' for j in JOBS.values()):
                        raise ValueError('An export is already running.')
                    job_id = uuid.uuid4().hex
                    JOBS[job_id] = dict(status='running', progress=0)
                threading.Thread(target=export_job, args=(job_id, meta.copy(), points, mode, size, trim), daemon=True).start()
                return self.json({'id': job_id})
            if self.path == '/api/cancel':
                job = JOBS[data['id']]
                if job['status'] == 'running':
                    job['cancelled'] = True
                    if job.get('process'):
                        job['process'].terminate()
                return self.json({'ok': True})
            return self.json({'error': 'Not found'}, 404)
        except (ValueError, KeyError, TypeError, subprocess.SubprocessError, OSError) as exc:
            return self.json({'error': str(exc)}, 400)

    def do_GET(self):
        path = urlparse(self.path).path
        if path.startswith('/api/jobs/'):
            job = JOBS.get(path.split('/')[-1])
            return self.json({k: v for k, v in job.items() if k != 'process'} if job else {'error': 'Not found'}, 200 if job else 404)
        if path.startswith('/media/'):
            meta = MEDIA.get(path.split('/')[-1])
            if not meta:
                return self.send_error(404)
            return self.file(Path(meta['path']), mimetypes.guess_type(meta['name'])[0] or 'video/mp4')
        if path.startswith('/exports/'):
            from urllib.parse import unquote
            target = (EXPORTS / unquote(path.removeprefix('/exports/'))).resolve()
            if target.parent != EXPORTS.resolve():
                return self.send_error(403)
            return self.file(target, 'video/mp4', download=True)
        target = (ROOT / 'static' / ('index.html' if path == '/' else path.lstrip('/'))).resolve()
        if target.parent != (ROOT / 'static').resolve():
            return self.send_error(403)
        return self.file(target, mimetypes.guess_type(target.name)[0] or 'application/octet-stream')

    def file(self, path, mime, download=False):
        if not path.is_file():
            return self.send_error(404)
        size = path.stat().st_size
        start, end = 0, size - 1
        range_header = self.headers.get('Range')
        if range_header:
            match = re.fullmatch(r'bytes=(\d*)-(\d*)', range_header)
            if not match or not any(match.groups()):
                return self.send_error(416)
            a, b = match.groups()
            if a:
                start, end = int(a), min(int(b), end) if b else end
            else:
                start = max(0, size - int(b))
            if start > end or start >= size:
                self.send_response(416)
                self.send_header('Content-Range', f'bytes */{size}')
                self.end_headers()
                return
        self.send_response(206 if range_header else 200)
        self.send_header('Content-Type', mime)
        self.send_header('Accept-Ranges', 'bytes')
        self.send_header('Content-Length', str(end - start + 1))
        if range_header:
            self.send_header('Content-Range', f'bytes {start}-{end}/{size}')
        if download:
            self.send_header('Content-Disposition', 'attachment; filename="danceframe-vertical.mp4"')
        self.end_headers()
        try:
            with path.open('rb') as f:
                f.seek(start)
                remaining = end-start+1
                while remaining:
                    chunk = f.read(min(1024*1024, remaining))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--port', type=int, default=8765)
    args = parser.parse_args()
    if not shutil.which('ffmpeg') or not shutil.which('ffprobe'):
        raise SystemExit('Install FFmpeg first: brew install ffmpeg')
    WORK.mkdir(exist_ok=True)
    EXPORTS.mkdir(exist_ok=True)
    httpd = ThreadingHTTPServer(('127.0.0.1', args.port), Handler)
    print(f'DanceFrame is running at http://127.0.0.1:{args.port}', flush=True)
    httpd.serve_forever()
