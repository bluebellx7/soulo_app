from http.server import ThreadingHTTPServer, SimpleHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlsplit
import time,json
root=Path('/tmp/SouloAdVideoQA')
class Handler(SimpleHTTPRequestHandler):
 def __init__(self,*a,**kw): super().__init__(*a,directory=str(root),**kw)
 def do_GET(self):
  path=urlsplit(self.path).path
  if path=='/slow-video.mp4':
   is_download=not self.headers.get('Range')
   if is_download:
    with open('/tmp/soulo-fast-download-requests.log','a') as f: f.write(json.dumps({'path':self.path,'time':time.time()})+'\n')
    time.sleep(8)
   self.path='/video.mp4'
  if path in ('/slow-tail','/slow-tail-blocked'):
   body=b'<!doctype html><meta name="viewport" content="width=device-width"><h1>Ready before slow resource</h1><script src="/stalled.js"></script>'
   if path=='/slow-tail': body=body.replace(b'<script src=',b'<script async src=')
   self.send_response(200);self.send_header('Content-Type','text/html');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body);return
  if path=='/stalled.js':
   time.sleep(20)
   self.send_response(200);self.send_header('Content-Length','0');self.end_headers();return
  super().do_GET()
ThreadingHTTPServer(('127.0.0.1',8918),Handler).serve_forever()
