# Kubernetes Jobs & CronJobs — MySQL Backup / Restore Demo

A hands-on demo of **backing up and restoring a MySQL database on Kubernetes**, using the
three building blocks you'd use in production: a **PersistentVolume** for the data, a
**Job** for a one-off `mysqldump` backup, and a **CronJob** to run that backup on a schedule.

```
Deployment (mysql) ──stores data──▶ PVC ──▶ PV (/data/mysql-data)   ← survives pod restarts
        ▲
        │ mysqldump over the "mysql" Service
        │
   Job / CronJob ──writes .sql──▶ hostPath (/home/azure/.../mysql-backups)
```

---

## What this demo teaches

### 1. Persistent storage (PV + PVC)
A database is useless if its data disappears when the pod restarts. This demo uses:
- A **PersistentVolume (PV)** — the actual storage (here a `hostPath` at `/data/mysql-data`).
- A **PersistentVolumeClaim (PVC)** — the pod's *request* for storage; the Deployment mounts
  the PVC at `/var/lib/mysql`.

So MySQL's data lives on the PV, **independent of the pod's lifecycle**.

### 2. Jobs — run a task once, to completion
A **Job** runs a pod until its task **finishes successfully**, then stops (unlike a
Deployment, which keeps pods running forever). That's exactly right for a backup: run
`mysqldump` once, write the `.sql` file, exit. `restartPolicy: OnFailure` means it retries
only if it fails.

### 3. CronJobs — run a Job on a schedule
A **CronJob** creates a Job automatically on a cron **schedule**. Here the schedule is
`*/1 * * * *` (**every minute**, for demo purposes) — in production you'd use something like
`0 2 * * *` for 2 AM daily. It's the Kubernetes-native way to do scheduled backups without a
cron daemon on a node.

### 4. How the backup travels
- The Job/CronJob container connects to MySQL over the **`mysql` Service** (`-h mysql`), runs
  `mysqldump`, and writes a timestamped file to `/backup`.
- `/backup` is a **hostPath** volume — a directory on the node — so the `.sql` files persist
  on the host and can be copied out or restored later.

> ⚠️ **Note on the passwords in these files:** the manifests hard-code
> `MYSQL_ROOT_PASSWORD` / `-pPass@12345` in plain text. That's fine for a learning demo, but
> in production these belong in a **Secret**, not in the YAML or the container args.

---

## Files in this repo

| File                    | What it is                                                                    |
|-------------------------|------------------------------------------------------------------------------|
| `mysql-pv-pvc.yaml`     | The PersistentVolume (1Gi `hostPath`) and the PersistentVolumeClaim.          |
| `mysql-deployment.yaml` | The MySQL Deployment (mounts the PVC) **and** the `mysql` Service on 3306.    |
| `mysql-backup-job.yaml` | A one-off **Job** that runs `mysqldump` and writes a timestamped `.sql`.      |
| `cronJob.yml`           | A **CronJob** that runs the same backup every minute (`*/1 * * * *`).         |
| `steps_for_backup.txt`  | The SQL to seed sample data, plus the restore commands.                       |

---

## Prerequisites

- A running Kubernetes cluster and `kubectl`.
- The **hostPath directories must exist on the node** (hostPath won't create them):
  - `/data/mysql-data` (the PV)
  - `/home/azure/jobs_init/data/mysql-backups` (the backup target — note `type: Directory`
    requires it to already exist)

  Create them on the node first, e.g.:
  ```bash
  sudo mkdir -p /data/mysql-data /home/azure/jobs_init/data/mysql-backups
  ```

---

## Steps

### 1. Create the storage (PV + PVC)
```bash
kubectl apply -f mysql-pv-pvc.yaml
kubectl get pv,pvc
```
Expected: the PVC shows `Bound` to `mysql-pv`.

### 2. Deploy MySQL and its Service
```bash
kubectl apply -f mysql-deployment.yaml
kubectl get pods -l app=mysql -w
```
Wait for the pod to be `1/1 Running`. (Press `Ctrl+C` to stop watching.)

### 3. Seed some sample data
Get the pod name and open a MySQL shell inside it:
```bash
POD=$(kubectl get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -- mysql -u root -pPass@12345 studentdb
```
Then create the table and insert rows (from `steps_for_backup.txt`):
```sql
CREATE TABLE students (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(100),
    course VARCHAR(100),
    city VARCHAR(100)
);

INSERT INTO students (name, course, city) VALUES
('Ashutosh', 'DevOps', 'Mumbai'),
('Rahul', 'AWS', 'Pune'),
('Priya', 'Azure', 'Bangalore'),
('Karan', 'Kubernetes', 'Delhi'),
('Sneha', 'Terraform', 'Hyderabad'),
('Vikram', 'Docker', 'Chennai');

SELECT * FROM students;
EXIT;
```

---

### 4. Take a one-off backup with a Job
```bash
kubectl apply -f mysql-backup-job.yaml
```

### 5. Watch the Job complete
```bash
kubectl get jobs
kubectl get pods -l job-name=mysql-backup-job
```
Expected — the Job reaches `COMPLETIONS 1/1`:
```
NAME               COMPLETIONS   DURATION   AGE
mysql-backup-job   1/1           5s         ...
```

### 6. Check the Job's logs and the backup file
```bash
kubectl logs job/mysql-backup-job
# → Taking MySQL backup...
# → Backup Completed.

# On the node, the .sql file is in the hostPath directory:
ls -l /home/azure/jobs_init/data/mysql-backups/
# → studentdb-2026-06-18-0947.sql
```

---

### 7. Automate it with a CronJob
```bash
kubectl apply -f cronJob.yml
kubectl get cronjob
```
Expected — the schedule is listed and `LAST SCHEDULE` updates each minute:
```
NAME                    SCHEDULE      SUSPEND   ACTIVE   LAST SCHEDULE
mysql-backup-cronjob    */1 * * * *   False     0        ...
```

### 8. Watch it fire (it runs every minute)
```bash
kubectl get jobs -w        # a new job appears each minute
```
Each run drops another timestamped `.sql` into the backup directory. In production change the
schedule to something sane like `0 2 * * *` (2 AM daily).

> **Tip:** keep only the last N backups with `successfulJobsHistoryLimit` /
> `failedJobsHistoryLimit` on the CronJob spec so old Jobs don't pile up.

---

## Restore from a backup

This proves the backup is real — drop the data and bring it back.

### 9. (Optional) simulate data loss
```bash
kubectl exec -it $POD -- mysql -u root -pPass@12345 studentdb -e "DROP TABLE students;"
```

### 10. Copy a backup file into the MySQL pod
```bash
# refresh POD in case the pod name changed
POD=$(kubectl get pod -l app=mysql -o jsonpath='{.items[0].metadata.name}')

kubectl cp /home/azure/jobs_init/data/mysql-backups/studentdb-2026-06-18-0947.sql \
  $POD:/tmp/studentdb.sql
```

### 11. Restore it into the database
```bash
kubectl exec -it $POD -- sh -c "mysql -u root -pPass@12345 studentdb < /tmp/studentdb.sql"
```

### 12. Verify the data is back
```bash
kubectl exec -it $POD -- mysql -u root -pPass@12345 studentdb -e "SELECT * FROM students;"
```
Expected: all your rows are back. ✅ Backup + restore round trip complete.

---

## Key takeaways

- **PV + PVC** keep the database's data alive across pod restarts.
- A **Job** runs a task once to completion — ideal for a one-off `mysqldump`.
- A **CronJob** runs that Job on a **schedule** — Kubernetes-native scheduled backups.
- The backup container reaches the DB over the **`mysql` Service** and writes to a
  **hostPath** so the `.sql` files survive on the node.
- **Restore** = `kubectl cp` the `.sql` into the pod, then pipe it into `mysql`.
- For real use: put credentials in a **Secret**, prefer a real storage class over `hostPath`,
  and set backup **history limits** on the CronJob.

---

## Cleanup

```bash
kubectl delete -f cronJob.yml
kubectl delete -f mysql-backup-job.yaml
kubectl delete -f mysql-deployment.yaml
kubectl delete -f mysql-pv-pvc.yaml
```
> The `.sql` files in the hostPath backup directory and the data in `/data/mysql-data` remain
> on the node — delete them manually if you want a completely clean slate.
