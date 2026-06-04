#!/usr/bin/env python3
from pathlib import Path

docs = Path("docs")
entries = []

for d in sorted(docs.iterdir()):
    if d.is_dir():
        entries.append(f'<li><a href="/{d.name}/">{d.name}</a></li>')

html = f"""
<html>
<head>
<title>Offline Documentation Portal</title>
<style>body {{ font-family: sans-serif; }}</style>
</head>
<body>
<h1>Documentation Mirror</h1>
<ul>
{''.join(entries)}
</ul>
</body>
</html>
"""

(docs / "index.html").write_text(html)
