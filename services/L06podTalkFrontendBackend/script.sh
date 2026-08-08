#!/bin/bash

mkdir -p k8s-project
cd k8s-project

########################################
# Namespace
########################################

cat > namespace.yml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: project
EOF

########################################
# Secret
########################################

cat > mysql-secret.yml <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: mysql-secret
  namespace: project
type: Opaque
stringData:
  MYSQL_ROOT_PASSWORD: Pass@12345
  MYSQL_DATABASE: studentdb
EOF

########################################
# MySQL Deployment
########################################

cat > mysql-deployment.yml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: mysql
  namespace: project

spec:
  replicas: 1

  selector:
    matchLabels:
      app: mysql

  template:
    metadata:
      labels:
        app: mysql

    spec:
      containers:

      - name: mysql

        image: mysql:8

        env:

        - name: MYSQL_ROOT_PASSWORD
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_ROOT_PASSWORD

        - name: MYSQL_DATABASE
          valueFrom:
            secretKeyRef:
              name: mysql-secret
              key: MYSQL_DATABASE

        ports:
        - containerPort: 3306
EOF

########################################
# MySQL Service
########################################

cat > mysql-service.yml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: mysql-service
  namespace: project

spec:
  selector:
    app: mysql

  ports:
  - port: 3306
    targetPort: 3306
EOF

########################################
# ConfigMap
########################################

cat > web-code.yml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-code
  namespace: project

data:
  app.py: |
    from flask import Flask,request
    import mysql.connector

    app = Flask(__name__)

    def conn():
        return mysql.connector.connect(
            host="mysql-service",
            user="root",
            password="Pass@12345",
            database="studentdb"
        )

    @app.route("/")
    def home():

        db = conn()
        cur = db.cursor()

        cur.execute("""
        CREATE TABLE IF NOT EXISTS users(
        id INT AUTO_INCREMENT PRIMARY KEY,
        name VARCHAR(50),
        location VARCHAR(50))
        """)

        db.commit()

        cur.execute("SELECT * FROM users")
        rows = cur.fetchall()

        html = """
        <h1>User Registration</h1>

        <form method='post' action='/add'>
        Name:<input name='name'><br><br>
        Location:<input name='location'><br><br>
        <input type='submit'>
        </form>

        <hr>
        """

        for row in rows:
            html += f"{row}<br>"

        return html

    @app.route("/add", methods=["POST"])
    def add():

        name = request.form["name"]
        location = request.form["location"]

        db = conn()
        cur = db.cursor()

        cur.execute(
            "INSERT INTO users(name,location) VALUES(%s,%s)",
            (name,location)
        )

        db.commit()

        return "<a href='/'>View Records</a>"

    app.run(host="0.0.0.0",port=5000)
EOF

########################################
# Frontend Deployment
########################################

cat > frontend-deployment.yml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: frontend
  namespace: project

spec:
  replicas: 3

  selector:
    matchLabels:
      app: frontend

  template:
    metadata:
      labels:
        app: frontend

    spec:
      containers:

      - name: frontend

        image: python:3.12-slim

        command:
        - sh
        - -c
        - |
          pip install flask mysql-connector-python
          python /app/app.py

        ports:
        - containerPort: 5000

        volumeMounts:
        - name: appcode
          mountPath: /app

      volumes:
      - name: appcode
        configMap:
          name: web-code
EOF

########################################
# Frontend Service
########################################

cat > frontend-service.yml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: frontend-service
  namespace: project

spec:
  type: NodePort

  selector:
    app: frontend

  ports:
  - port: 5000
    targetPort: 5000
    nodePort: 30080
EOF

echo "Files created successfully."

ls -1
