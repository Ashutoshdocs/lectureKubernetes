#!/bin/bash
mkdir -p frontend sidecar k8s
####################################
# FRONTEND
####################################
cat > frontend/app.py <<'EOF'
from flask import Flask, request, send_file, Response
import os, time
app = Flask(__name__)

HTML = """
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Hall Ticket Generator</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    font-family: -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    background: linear-gradient(135deg, #0f2b46 0%, #1c4b7a 100%);
    min-height: 100vh; display: flex; align-items: center; justify-content: center;
    padding: 24px; color: #0f2b46;
  }
  .card {
    background: #fff; width: 100%; max-width: 440px; border-radius: 16px;
    box-shadow: 0 20px 50px rgba(0,0,0,.35); overflow: hidden;
  }
  .head {
    background: #0f2b46; color: #fff; padding: 28px 32px 22px; text-align: center;
    border-bottom: 5px solid #c8102e;
  }
  .head h2 { font-size: 22px; letter-spacing: .5px; }
  .head p { margin-top: 6px; font-size: 13px; opacity: .8; }
  form { padding: 28px 32px 34px; }
  label { display: block; font-size: 12px; font-weight: 600; letter-spacing: .4px;
    text-transform: uppercase; color: #6b7280; margin: 16px 0 6px; }
  input {
    width: 100%; padding: 12px 14px; border: 1.5px solid #dfe4ea; border-radius: 9px;
    font-size: 15px; transition: border-color .15s, box-shadow .15s;
  }
  input:focus { outline: none; border-color: #1c4b7a; box-shadow: 0 0 0 3px rgba(28,75,122,.15); }
  button {
    width: 100%; margin-top: 26px; padding: 14px; border: 0; border-radius: 9px;
    background: #c8102e; color: #fff; font-size: 15px; font-weight: 700;
    letter-spacing: .5px; cursor: pointer; transition: background .15s, transform .05s;
  }
  button:hover { background: #a60d26; }
  button:active { transform: translateY(1px); }
  .note { margin-top: 16px; font-size: 12px; color: #9aa3ad; text-align: center; }
</style>
</head>
<body>
  <div class="card">
    <div class="head">
      <h2>Hall Ticket Generator</h2>
      <p>National Institute of Technology &middot; Examination Cell</p>
    </div>
    <form action="/generate" method="post">
      <label>Candidate Name</label>
      <input name="username" placeholder="e.g. Aarav Sharma" required>
      <label>Batch</label>
      <input name="batch" placeholder="e.g. 2024" required>
      <label>Course / Programme</label>
      <input name="course" placeholder="e.g. B.Tech Computer Science" required>
      <button type="submit">Generate Admit Card (PDF)</button>
      <div class="note">The PDF is rendered by the Kubernetes sidecar.</div>
    </form>
  </div>
</body>
</html>
"""

@app.route("/")
def home():
    return HTML

@app.route("/generate", methods=["POST"])
def generate():
    username = request.form["username"]
    batch = request.form["batch"]
    course = request.form["course"]
    if os.path.exists("/shared/hallticket.pdf"):
        os.remove("/shared/hallticket.pdf")
    with open("/shared/request.txt", "w") as f:
        f.write(f"{username}|{batch}|{course}")
    for _ in range(30):
        if os.path.exists("/shared/hallticket.pdf"):
            return send_file("/shared/hallticket.pdf", as_attachment=True,
                             download_name="admit_card.pdf")
        time.sleep(1)
    return Response("PDF Generation Failed", status=500)

app.run(host="0.0.0.0", port=8080)
EOF
cat > frontend/requirements.txt <<'EOF'
flask
EOF
cat > frontend/Dockerfile <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY app.py .
EXPOSE 8080
CMD ["python","app.py"]
EOF
####################################
# SIDECAR
####################################
cat > sidecar/sidecar.py <<'EOF'
from reportlab.pdfgen import canvas
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib.colors import HexColor
import os, time, hashlib, datetime

W, H = A4

def make_admit_card(path, username, batch, course):
    username = (username or "").strip()
    batch = (batch or "").strip()
    course = (course or "").strip()

    navy   = HexColor("#0f2b46")
    accent = HexColor("#c8102e")
    light  = HexColor("#eef2f6")
    gray   = HexColor("#6b7280")
    line   = HexColor("#dfe4ea")
    white  = HexColor("#ffffff")

    seed = f"{username}{batch}{course}".encode()
    h = int(hashlib.sha1(seed).hexdigest(), 16)
    roll = f"{(batch[:3].upper() or 'BAT')}{h % 100000:05d}"
    seat = f"S-{h % 300 + 1:03d}"
    exam_date = (datetime.date.today() + datetime.timedelta(days=15)).strftime("%d %B %Y")

    c = canvas.Canvas(path, pagesize=A4)
    margin = 15 * mm

    # Outer + inner border
    c.setStrokeColor(navy); c.setLineWidth(2)
    c.rect(margin, margin, W - 2*margin, H - 2*margin)
    c.setLineWidth(0.6)
    c.rect(margin + 4, margin + 4, W - 2*margin - 8, H - 2*margin - 8)

    left  = margin + 4
    right = W - margin - 4
    top   = H - margin - 4
    inner_w = right - left

    # Header band
    band_h = 66
    c.setFillColor(navy)
    c.rect(left, top - band_h, inner_w, band_h, fill=1, stroke=0)

    # Seal
    cxs, cys = left + 40, top - band_h/2
    c.setStrokeColor(white); c.setLineWidth(1.2)
    c.circle(cxs, cys, 20, fill=0, stroke=1)
    c.setFillColor(white); c.setFont("Helvetica-Bold", 7)
    c.drawCentredString(cxs, cys + 2, "EST.")
    c.drawCentredString(cxs, cys - 7, "1962")

    c.setFillColor(white)
    c.setFont("Helvetica-Bold", 19)
    c.drawCentredString(W/2 + 10, top - 28, "NATIONAL INSTITUTE OF TECHNOLOGY")
    c.setFont("Helvetica", 9.5)
    c.drawCentredString(W/2 + 10, top - 44, "Office of the Controller of Examinations")

    # Accent strip
    c.setFillColor(accent)
    c.rect(left, top - band_h - 5, inner_w, 5, fill=1, stroke=0)

    # Title
    ty = top - band_h - 30
    c.setFillColor(navy)
    c.setFont("Helvetica-Bold", 15)
    c.drawCentredString(W/2, ty, "ADMIT CARD  /  HALL TICKET")

    # Photo box
    pw, ph = 33*mm, 42*mm
    px = right - 22 - pw
    cy = ty - 24
    py = cy - ph
    c.setFillColor(light); c.setStrokeColor(gray); c.setLineWidth(1)
    c.rect(px, py, pw, ph, fill=1, stroke=1)
    c.setFillColor(gray); c.setFont("Helvetica", 8)
    c.drawCentredString(px + pw/2, py + ph/2 + 4, "AFFIX RECENT")
    c.drawCentredString(px + pw/2, py + ph/2 - 6, "PHOTOGRAPH")

    # Detail rows
    fields = [
        ("Candidate Name", username or "-"),
        ("Roll Number", roll),
        ("Batch", batch or "-"),
        ("Programme", course or "-"),
        ("Examination", "End Semester Examination"),
        ("Exam Date", exam_date),
        ("Reporting Time", "09:00 AM"),
        ("Exam Center", "Main Campus, Block A"),
        ("Seat Number", seat),
    ]
    cxl = left + 22
    row_y = cy - 8
    row_h = 32
    for label, value in fields:
        c.setFillColor(gray); c.setFont("Helvetica", 8)
        c.drawString(cxl, row_y, label.upper())
        c.setFillColor(navy); c.setFont("Helvetica-Bold", 12)
        c.drawString(cxl, row_y - 14, str(value))
        c.setStrokeColor(line); c.setLineWidth(0.5)
        c.line(cxl, row_y - 21, px - 16, row_y - 21)
        row_y -= row_h

    # Instructions
    iy = row_y - 6
    c.setFillColor(navy); c.setFont("Helvetica-Bold", 10)
    c.drawString(cxl, iy, "INSTRUCTIONS TO CANDIDATES")
    c.setStrokeColor(accent); c.setLineWidth(1.2)
    c.line(cxl, iy - 4, cxl + 150, iy - 4)

    instructions = [
        "Carry this admit card along with a valid photo ID to the examination hall.",
        "Report to the examination center at least 30 minutes before reporting time.",
        "Electronic devices, including mobile phones, are strictly prohibited inside.",
        "Preserve this admit card and produce it for all subsequent examinations.",
        "Report any discrepancy in the details to the examination office immediately.",
    ]
    ly = iy - 20
    for i, txt in enumerate(instructions, 1):
        c.setFillColor(accent); c.setFont("Helvetica-Bold", 9)
        c.drawString(cxl, ly, f"{i}.")
        c.setFillColor(HexColor("#333333")); c.setFont("Helvetica", 9)
        c.drawString(cxl + 14, ly, txt)
        ly -= 16

    # Signatures
    sy = margin + 70
    c.setStrokeColor(navy); c.setLineWidth(0.8)
    c.line(left + 30, sy, left + 170, sy)
    c.line(right - 170, sy, right - 30, sy)
    c.setFillColor(gray); c.setFont("Helvetica", 9)
    c.drawCentredString(left + 100, sy - 12, "Candidate's Signature")
    c.drawCentredString(right - 100, sy - 12, "Controller of Examinations")

    # Footer
    c.setFillColor(navy)
    c.rect(left, margin + 4, inner_w, 22, fill=1, stroke=0)
    c.setFillColor(white); c.setFont("Helvetica-Oblique", 8)
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    c.drawCentredString(W/2, margin + 11,
        f"Auto-generated by Kubernetes Sidecar  |  {stamp}  |  This is a computer-generated document.")

    c.save()

while True:
    if os.path.exists("/shared/request.txt"):
        try:
            with open("/shared/request.txt") as f:
                data = f.read()
            parts = data.split("|")
            if len(parts) == 3:
                username, batch, course = parts
                make_admit_card("/shared/hallticket.pdf", username, batch, course)
            os.remove("/shared/request.txt")
        except Exception as e:
            print("sidecar error:", e, flush=True)
    time.sleep(2)
EOF
cat > sidecar/Dockerfile <<'EOF'
FROM python:3.11-slim
WORKDIR /app
COPY sidecar.py .
RUN pip install reportlab
CMD ["python","sidecar.py"]
EOF
####################################
# DEPLOYMENT
####################################
cat > k8s/deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hallticket-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: hallticket
  template:
    metadata:
      labels:
        app: hallticket
    spec:
      volumes:
      - name: shared-data
        emptyDir: {}
      containers:
      - name: frontend
        image: hallticket-frontend:v1
        imagePullPolicy: Never
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: shared-data
          mountPath: /shared
      - name: pdf-sidecar
        image: hallticket-sidecar:v1
        imagePullPolicy: Never
        volumeMounts:
        - name: shared-data
          mountPath: /shared
EOF
####################################
# SERVICE
####################################
cat > k8s/service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: hallticket-service
spec:
  type: NodePort
  selector:
    app: hallticket
  ports:
  - port: 8080
    targetPort: 8080
    nodePort: 30080
EOF
echo "PROJECT CREATED"
