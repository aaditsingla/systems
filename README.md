# User & Group Management Script

A comprehensive Bash script for Linux administrators to manage users and groups efficiently. Supports both interactive, menu-driven operations and batch CSV processing, with full auditing via system logs.

---

## Features

### User Management
- Create new users (with prompts for username, full name, and password)
- Delete users (backs up home directory to `/var/backups/user_homes` before deletion)
- Modify users (change password, shell, full name, or home directory)
- Lock and unlock user accounts

### Group Management
- Create new groups
- Delete groups (warns if group is a primary group for users)
- Add users to groups

### Batch Processing
- Process users and groups from a CSV file
- Automatically create missing groups
- Lock passwords for newly created users by default
- Handles empty lines, comments, and trailing commas in CSV files
- Logs all batch actions and errors

### Logging
- All actions (create, modify, delete, batch) are logged using the `logger` command under the tag `user_project` for system-wide auditing.
- On-screen logs also include timestamps for user visibility and troubleshooting.

---

## Requirements

- Linux system with Bash shell
- Root privileges (script auto-executes with `sudo` if needed)
- Standard Linux utilities: `useradd`, `usermod`, `groupadd`, `groupdel`, `passwd`, `tar`, `logger`

---

## Installation & Setup

You can install and use this script in two ways:

1. **Clone from GitHub:**
git clone https://github.com/pkz074/user-management-script.git

2. **Or download the script file directly** to any directory on your Ubuntu system.

After downloading or cloning, **navigate to the directory** where the file is saved.
Then, make sure the script is executable:

chmod +x user-mng.sh

Run the script using `sudo` (to get administrative privileges):

sudo ./user-mng.sh
