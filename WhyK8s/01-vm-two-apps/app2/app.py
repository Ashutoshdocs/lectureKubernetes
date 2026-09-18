from jinja2 import Environment, FileSystemLoader
from wsgiref.simple_server import make_server
import os, json

env = Environment(loader=FileSystemLoader(os.path.join(os.path.dirname(__file__), "templates")))
template = env.get_template("index.html")
VERSION = os.getenv("APP_VERSION", "v1")
MODEL = os.getenv("DEPLOYMENT_MODEL", "Manual VM")

def application(environ, start_response):
    if environ.get("PATH_INFO") == "/health":
        body = json.dumps({
            "status": "healthy",
            "app": "GreenPulse",
            "jinja": __import__("jinja2").__version__
        }).encode()
        start_response("200 OK", [("Content-Type","application/json"),("Content-Length",str(len(body)))])
        return [body]
    body = template.render(version=VERSION, model=MODEL, jinja=__import__("jinja2").__version__).encode()
    start_response("200 OK", [("Content-Type","text/html; charset=utf-8"),("Content-Length",str(len(body)))])
    return [body]

if __name__ == "__main__":
    make_server("0.0.0.0", 8080, application).serve_forever()
