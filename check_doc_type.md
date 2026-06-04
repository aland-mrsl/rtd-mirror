# 1. Check if it's RTD
curl -s "https://readthedocs.org/api/v2/project/?slug=<name>" | python3 -m json.tool

# 2. Check for a GitHub source link
# Look in the site's footer, or search: site:github.com "<site name>" docs

# 3. Once you have the repo, check SSG
curl -s https://api.github.com/repos/<owner>/<repo>/contents/ | \
  python3 -c "import sys,json; files=[f['name'] for f in json.load(sys.stdin)]; print(files)"
# Look for: hugo.toml, next.config.js, mkdocs.yml, conf.py, docusaurus.config.js