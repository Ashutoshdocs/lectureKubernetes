# Kubernetes HostPath Volume Types — Hands-On Demo

## Objective

Understand how Kubernetes `hostPath` behaves with different `type` values.

We will demonstrate:

1. `Directory`
2. `DirectoryOrCreate`
3. `File`
4. `FileOrCreate`

---

# 1. Directory

## Meaning

```yaml
type: Directory
```

The directory **must already exist on the Kubernetes node**.

If the directory does not exist, the Pod will not start successfully.

### Pod YAML

Create `01-directory.yaml`:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: hostpath-directory

spec:

  containers:

    - name: nginx
      image: nginx:latest

      volumeMounts:
        - name: my-volume
          mountPath: /data

  volumes:

    - name: my-volume
      hostPath:
        path: /data/directory-demo
        type: Directory
```

## Step 1 — Check the node

```bash
ls -ld /data/directory-demo
```

If it does not exist, create it:

```bash
mkdir -p /data/directory-demo
```

## Step 2 — Create the Pod

```bash
kubectl apply -f 01-directory.yaml
```

Check:

```bash
kubectl get pod hostpath-directory
```

Expected:

```text
NAME                READY   STATUS
hostpath-directory  1/1     Running
```

## Step 3 — Test the mount

```bash
kubectl exec hostpath-directory -- sh
```

Inside the container:

```bash
ls -la /data
```

Create a file:

```bash
echo "Hello from Directory" > /data/test.txt
```

Exit:

```bash
exit
```

On the node:

```bash
cat /data/directory-demo/test.txt
```

Output:

```text
Hello from Directory
```

---

# 2. DirectoryOrCreate

## Meaning

```yaml
type: DirectoryOrCreate
```

If the directory already exists:

```text
Use it
```

If it does not exist:

```text
Create it automatically
```

### Pod YAML

Create `02-directory-or-create.yaml`:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: hostpath-directory-create

spec:

  containers:

    - name: nginx
      image: nginx:latest

      volumeMounts:
        - name: my-volume
          mountPath: /data

  volumes:

    - name: my-volume
      hostPath:
        path: /data/auto-created
        type: DirectoryOrCreate
```

## Step 1 — Make sure the directory does NOT exist

```bash
rm -rf /data/auto-created
```

Verify:

```bash
ls -ld /data/auto-created
```

Expected:

```text
No such file or directory
```

## Step 2 — Create the Pod

```bash
kubectl apply -f 02-directory-or-create.yaml
```

Check:

```bash
kubectl get pod hostpath-directory-create
```

Expected:

```text
NAME                       READY   STATUS
hostpath-directory-create  1/1     Running
```

## Step 3 — Check the node

```bash
ls -ld /data/auto-created
```

The directory has been automatically created.

## Key Point

```text
Directory
    ↓
Must already exist

DirectoryOrCreate
    ↓
Create automatically if missing
```

---

# 3. File

## Meaning

```yaml
type: File
```

The file **must already exist on the Kubernetes node**.

If the file does not exist, the Pod will not start successfully.

### Step 1 — Create the file

On the node:

```bash
mkdir -p /data
```

Create:

```bash
echo "Hello from HostPath File" > /data/app.txt
```

Verify:

```bash
cat /data/app.txt
```

Output:

```text
Hello from HostPath File
```

### Pod YAML

Create `03-file.yaml`:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: hostpath-file

spec:

  containers:

    - name: nginx
      image: nginx:latest

      volumeMounts:
        - name: my-file
          mountPath: /data/app.txt

  volumes:

    - name: my-file
      hostPath:
        path: /data/app.txt
        type: File
```

## Step 2 — Create the Pod

```bash
kubectl apply -f 03-file.yaml
```

Check:

```bash
kubectl get pod hostpath-file
```

## Step 3 — Read the file

```bash
kubectl exec hostpath-file -- cat /data/app.txt
```

Output:

```text
Hello from HostPath File
```

---

# 4. FileOrCreate

## Meaning

```yaml
type: FileOrCreate
```

If the file exists:

```text
Use it
```

If the file does not exist:

```text
Create it automatically
```

### Pod YAML

Create `04-file-or-create.yaml`:

```yaml
apiVersion: v1
kind: Pod

metadata:
  name: hostpath-file-create

spec:

  containers:

    - name: nginx
      image: nginx:latest

      volumeMounts:
        - name: my-file
          mountPath: /data/app.log

  volumes:

    - name: my-file
      hostPath:
        path: /data/app.log
        type: FileOrCreate
```

## Step 1 — Make sure the file does NOT exist

```bash
rm -f /data/app.log
```

Check:

```bash
ls -l /data/app.log
```

Expected:

```text
No such file or directory
```

## Step 2 — Create the Pod

```bash
kubectl apply -f 04-file-or-create.yaml
```

Check:

```bash
kubectl get pod hostpath-file-create
```

Expected:

```text
NAME                    READY   STATUS
hostpath-file-create    1/1     Running
```

## Step 3 — Check the node

```bash
ls -l /data/app.log
```

The file has been automatically created.

---

# Comparison

| Type                | Path      | Must Already Exist? | Automatically Created? |
| ------------------- | --------- | ------------------: | ---------------------: |
| `Directory`         | Directory |                 Yes |                     No |
| `DirectoryOrCreate` | Directory |                  No |                    Yes |
| `File`              | File      |                 Yes |                     No |
| `FileOrCreate`      | File      |                  No |                    Yes |

---

# Easy Memory Trick

```text
Directory
    ↓
Existing Directory

DirectoryOrCreate
    ↓
Directory + Create

File
    ↓
Existing File

FileOrCreate
    ↓
File + Create
```

---

# Important Difference

## Directory

```yaml
type: Directory
```

Requires:

```text
/data/mydir
```

to already exist.

---

## DirectoryOrCreate

```yaml
type: DirectoryOrCreate
```

Kubernetes creates:

```text
/data/mydir
```

if it is missing.

---

## File

```yaml
type: File
```

Requires:

```text
/data/myfile
```

to already exist.

---

## FileOrCreate

```yaml
type: FileOrCreate
```

Kubernetes creates:

```text
/data/myfile
```

if it is missing.

---

# Cleanup

Delete all demonstration Pods:

```bash
kubectl delete pod \
  hostpath-directory \
  hostpath-directory-create \
  hostpath-file \
  hostpath-file-create
```

Clean the test files/directories from the node:

```bash
rm -rf /data/directory-demo
rm -rf /data/auto-created
rm -f /data/app.txt
rm -f /data/app.log
```

---

# Final Classroom Summary

```text
                    hostPath
                       |
          +------------+------------+
          |                         |
      Directory                   File
          |                         |
     +----+----+               +----+----+
     |         |               |         |
 Directory  Directory        File     File
            OrCreate                   OrCreate
     |         |               |         |
   Must      Create          Must      Create
   exist     if missing      exist     if missing
```

## One-Line Rule

> `Directory` and `File` require the path to exist. `DirectoryOrCreate` and `FileOrCreate` can create the missing path.
