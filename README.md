# DevOps Intern Stage 1 Task — Automated Deployment Script

## 🚀 Overview

This project contains an automated **Bash deployment script (`deploy.sh`)** designed for the **HNG DevOps Internship Stage 1 Task**. It simulates a real-world DevOps workflow: automating the setup, deployment, and configuration of a Dockerized application on a remote Linux server.

The script performs **end-to-end automation** — from cloning a Git repository to configuring Nginx as a reverse proxy — with robust logging, validation, and error handling.

---

## 🧩 Features

* Collects and validates user input interactively.
* Clones or updates a Git repository using a **Personal Access Token (PAT)**.
* Connects to a remote server via **SSH**.
* Automatically installs and configures **Docker**, **Docker Compose**, and **Nginx**.
* Deploys the application using **Dockerfile** or **docker-compose.yml**.
* Configures **Nginx** as a reverse proxy for HTTP traffic.
* Performs **health checks** and **validation**.
* Implements **idempotency** — can re-run safely without breaking existing setups.
* Includes `--cleanup` mode to tear down deployed resources.

---

## 🛠️ Requirements

* Local system with:

  * Bash (v4 or later)
  * Git
  * SSH access to the remote server
* Remote server running Ubuntu or Debian
* Docker-compatible project (must contain `Dockerfile` or `docker-compose.yml`)

---

## ⚙️ How It Works

### 1. Input Collection

Prompts the user for:

* Git Repository URL
* Personal Access Token (PAT)
* Branch (default: `main`)
* SSH credentials: username, server IP, and key path
* Application internal port (e.g., 3000)

### 2. Repository Handling

* Clones the repository if not present
* Pulls latest updates if it already exists
* Checks out the specified branch

### 3. Remote Preparation

Over SSH, the script:

* Updates system packages
* Installs **Docker**, **Docker Compose**, and **Nginx**
* Enables and starts required services

### 4. Application Deployment

* Transfers project files via **rsync**
* Builds and runs Docker containers
* Exposes the container internally on the specified port

### 5. Nginx Configuration

* Creates an Nginx site file that proxies port 80 → internal app port
* Reloads Nginx configuration

### 6. Validation

Verifies that:

* Docker service is active
* The container is running and healthy
* Nginx is successfully proxying traffic

### 7. Logging

All activities are logged to a file named `deploy_YYYYMMDD_HHMMSS.log` in the local directory.

### 8. Cleanup Mode

Run with `--cleanup` to:

* Stop and remove deployed containers
* Delete transferred project files
* Remove Nginx configuration

Example:

```bash
./deploy.sh --cleanup
```

---

## 🚀 Usage

1. Clone this repository:

   ```bash
   git clone https://github.com/beekyynd/hng13-stage1-devops.git
   cd hng13-stage1-devops
   ```

2. Make the script executable:

   ```bash
   chmod +x deploy.sh
   ```

3. Run interactively:

   ```bash
   ./deploy.sh
   ```

4. When prompted, enter your Git repo URL, PAT, SSH details, and application port.

---

## 🔒 Security Notes

* The **Personal Access Token (PAT)** is only used for cloning. Avoid storing it in plain text.
* Run the script in a secure environment (e.g., local development or CI/CD system).
* Always verify remote SSH key authenticity before connecting.

---

## 🧪 Example Output

After a successful deployment, you’ll see logs like:

```
[2025-10-20 10:31:55] INFO: Starting deployment script
[2025-10-20 10:31:56] INFO: Cloning repository
[2025-10-20 10:32:14] INFO: Preparing remote environment
[2025-10-20 10:33:01] INFO: Nginx configured and reloaded
[2025-10-20 10:33:22] INFO: Deployment complete
```

---

## 🧹 Cleanup Example

To completely remove the app and configuration from the remote server:

```bash
./deploy.sh --cleanup
```

---

## 🧠 Author

**Francis Kalu**
