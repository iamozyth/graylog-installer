# Graylog Open Installer

This repository contains a **Bash-based installer wizard** for deploying **Graylog Open** in a small clustered setup on **Ubuntu Server**.

The goal of this project is to provide a **safe, deterministic, and supportable installation workflow** for customer environments, without overengineering or unnecessary dependencies.

---

## Target Architecture

- **1× Graylog Server**
  - Graylog Open
  - MongoDB (local)
- **2× Graylog Data Nodes**
  - Graylog Data Node
  - Dedicated data disks

The installer is designed to be executed **locally on each host**, with role-based behavior.

---

## Supported Operating Systems

Officially supported by this installer:

- Ubuntu Server **22.04 LTS**
- Ubuntu Server **24.04 LTS**

Architecture:
- x86_64 only

Other distributions are **explicitly rejected** by preflight checks.

---

## What v1 Does

Version 1 focuses on **system preflight, baseline enforcement, and safety**.

### Implemented Features

- Root privilege enforcement
- OS and architecture validation
- Timezone enforcement:
  - `Europe/Berlin`
- NTP configuration:
  - Default:
    - `0.de.pool.ntp.org`
    - `1.de.pool.ntp.org`
    - `2.de.pool.ntp.org`
    - `3.de.pool.ntp.org`
  - Optional user-defined NTP servers during installation
- Kernel tuning:
  - Ensures `vm.max_map_count >= 262144`
- Role selection:
  - Graylog Server
  - Graylog Data Node
- Java runtime validation:
  - Ensures OpenJDK 17 is installed
- Structured logging:
  - `/var/log/graylog-installer.log`

All checks are **explicit and auditable**.

---

## What v1 Does NOT Do

The following are intentionally **out of scope for v1** and will be added in later versions:

- Graylog package installation
- MongoDB installation and compatibility enforcement
- Disk selection and formatting for Data Nodes
- Graylog configuration generation
- Firewall configuration
- Service startup and validation

This separation ensures that **destructive or complex actions** are only introduced once the baseline is proven stable.

---

## Usage

Run the installer directly on the target host:

```bash
sudo bash graylog-install-v1.sh
