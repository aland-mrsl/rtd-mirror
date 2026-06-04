import pathlib
import requests

def get_htmlzip_url(project):
    """
    Returns the HTML zip download URL for a Read the Docs project, or None if not available
    """
    project = project.strip()
    if project.startswith("http"):
        return None

    return f"https://{project}.readthedocs.io/_/downloads/en/stable/htmlzip/"

def download_file(url, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with requests.get(url, stream=True) as r:
        if r.status_code != 200:
            return False
        with open(target, "wb") as f:
            for chunk in r.iter_content(chunk_size=8192):
                f.write(chunk)
    return True
