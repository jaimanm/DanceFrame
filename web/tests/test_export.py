import json
import math
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import server

class ValidationTests(unittest.TestCase):
    def test_rejects_bad_points(self):
        for points in [[], [{'t': 1, 'x': math.nan}], [{'t': -1, 'x': .5}], [{'t': 1, 'x': .5}, {'t': 1, 'x': .8}]]:
            with self.assertRaises(ValueError):
                server.validate_points(points, {'duration': 2})

    def test_rejects_invalid_trim(self):
        for trim in [{'start':-1,'end':1},{'start':1,'end':1},{'start':0,'end':3},{'start':0,'end':math.nan}]:
            with self.assertRaises(ValueError):
                server.validate_trim(trim,{'duration':2,'fps':24})

class ExportTests(unittest.TestCase):
    def test_motion_audio_and_dimensions(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            source=root/'gradient.mp4'
            subprocess.run(['ffmpeg','-v','error','-f','lavfi','-i',"nullsrc=s=640x360:r=24:d=2,geq=lum='16+200*X/W':cb=128:cr=128",'-f','lavfi','-i','sine=frequency=440:duration=2','-c:v','libx264','-crf','12','-pix_fmt','yuv420p','-c:a','aac','-shortest',str(source)],check=True)
            meta=server.probe(source)
            meta.update(name='gradient.mp4',path=str(source))
            points=[{'t':.25,'x':0},{'t':1.75,'x':1}]
            for mode, trim in [('smooth',None),('linear',None),('smooth',{'start':.5,'end':1.5})]:
                job_id=mode+('-trim' if trim else '')
                jobs={job_id:dict(status='running',progress=0)}
                with patch.object(server,'WORK',root),patch.object(server,'EXPORTS',root),patch.object(server,'JOBS',jobs):
                    server.export_job(job_id,meta,points,mode,'720',trim)
                self.assertEqual(jobs[job_id]['status'],'done',jobs[job_id].get('error'))
                output=root/jobs[job_id]['filename']
                data=json.loads(subprocess.check_output(['ffprobe','-v','error','-show_streams','-show_format','-of','json',str(output)]))
                self.assertEqual((data['streams'][0]['width'],data['streams'][0]['height']),(720,1280))
                self.assertTrue(any(s['codec_type']=='audio' for s in data['streams']))
                if trim:
                    self.assertAlmostEqual(float(data['format']['duration']),1,delta=.1)
                for local_t in ([0,.25,.5,.875] if trim else [0,.25,.5,1,1.5,1.875]):
                    t=local_t+(trim['start'] if trim else 0)
                    u=max(0,min(1,(t-.25)/1.5));u=u if mode=='linear' else u*u*(3-2*u)
                    x=math.floor(u*(640-meta['cropWidth']))
                    expected=self.mean(source,t,f"crop={meta['cropWidth']}:{meta['cropHeight']}:{x}:0:exact=1,scale=720:1280:flags=lanczos,scale=1:1")
                    actual=self.mean(output,local_t,'scale=1:1')
                    self.assertLessEqual(abs(expected-actual),3,f'{mode} t={t}: actual={actual}, expected={expected}')

    @staticmethod
    def mean(path,t,filters):
        data=subprocess.check_output(['ffmpeg','-v','error','-i',str(path),'-ss',str(t),'-frames:v','1','-vf',filters,'-pix_fmt','gray','-f','rawvideo','pipe:1'])
        return data[0]

if __name__=='__main__':unittest.main()
