"""Assemble web/ into a folder for publishing the static preview as a claude.ai Artifact (page body + inlined CSS as
musicscan.html, plus js/, vendor/, samples/, demo/). Usage: python3 scripts/build_preview.py <outDir>. Writes <outDir>.files.json."""
import sys, re, shutil, os, json
R=os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'web'); P=sys.argv[1]
shutil.rmtree(P, ignore_errors=True); os.makedirs(P)
for d in ['js','samples','demo','vendor']: shutil.copytree(f'{R}/{d}', f'{P}/{d}')
os.remove(f'{P}/vendor/LICENSE.vexflow')
s=open(f'{R}/index.html').read()
head, body = s.split('<body', 1)
body = '<body' + body
body = re.sub(r'^<body[^>]*>', '', body).replace('</body>','').replace('</html>','')
css=''.join(open(f'{R}/{h}').read()+'\n' for h in re.findall(r'<link rel="stylesheet" href="([^"]+)"', head))
title=re.search(r'<title>.*?</title>', head).group(0)
assert not re.search(r'<body [^>]*class', s), 'body has attributes'
open(f'{P}/musicscan.html','w').write(title+'\n<meta charset="utf-8">\n<style>\n'+css+'</style>\n'+body)
files=[]
for root,_,fs in os.walk(P):
    for f in fs:
        rel=os.path.relpath(os.path.join(root,f),P)
        if rel!='musicscan.html': files.append(rel)
ok={'.js','.mjs','.json','.jpg','.png','.mp3','.txt','.css','.svg'}
bad=[f for f in files if os.path.splitext(f)[1] not in ok]
print('bad',bad); print(len(files)); json.dump([{'path':f} for f in sorted(files)], open(P+'.files.json','w'))
