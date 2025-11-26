#!/bin/bash
#===============================================================================
# User Account Management Script
# Purpose: Comprehensive user and group management with robust error handling
# Usage: sudo ./script.sh [--file users.csv] for batch mode
#        sudo ./script.sh for interactive mode
#===============================================================================

set -u
set -o pipefail

# Global Variables
LOG_TAG="user_project"
BACKUP_DIR="/var/backups/user_homes"
SCRIPT_NAME=$(basename "$0")

#===============================================================================
# Privilege Check
#===============================================================================
if [ "$EUID" -ne 0 ]; then
    echo "ERROR: This script must be run as root."
    echo "Re-executing with sudo..."
    exec sudo "$0" "$@"
fi

#===============================================================================
# Logging Function
#===============================================================================
log_action(){
    local message="$1"
    logger -t "$LOG_TAG" -p user.info "$message"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $message"
}

#===============================================================================
# Utility Functions
#===============================================================================
pause_prompt() {
    echo ""
    read -p "Press Enter to continue..." -r
}

# Display user list in compact format
display_user_list() {
    echo ""
    echo "--- Available Users ---"
    awk -F: '($3 >= 1000 && $1 != "nobody") {print "  •", $1, "(UID:", $3")"}' /etc/passwd | sort
    echo "----------------------"
    echo ""
}

# Display group list in compact format
display_group_list() {
    echo ""
    echo "--- Available Groups ---"
    awk -F: '($3 >= 1000 || $1 ~ /^(sudo|wheel|docker|admin|users)$/) {print "  •", $1, "(GID:", $3")"}' /etc/group | sort
    echo "------------------------"
    echo ""
}

# Display user details with groups
display_user_details() {
    local username="$1"
    local user_info
    user_info=$(getent passwd "$username")
    
    if [ -z "$user_info" ]; then
        return 1
    fi
    
    local uid=$(echo "$user_info" | cut -d: -f3)
    local fullname=$(echo "$user_info" | cut -d: -f5)
    local homedir=$(echo "$user_info" | cut -d: -f6)
    local shell=$(echo "$user_info" | cut -d: -f7)
    local user_groups=$(groups "$username" 2>/dev/null | cut -d: -f2)
    local account_status
    
    if passwd -S "$username" 2>/dev/null | grep -q " L "; then
        account_status="🔒 LOCKED"
    else
        account_status="🔓 UNLOCKED"
    fi
    
    echo ""
    echo "┌─── User Information ───────────────────"
    echo "│ Username:    $username"
    echo "│ UID:         $uid"
    echo "│ Full Name:   ${fullname:-Not set}"
    echo "│ Home:        $homedir"
    echo "│ Shell:       $shell"
    echo "│ Status:      $account_status"
    echo "│ Groups:     $user_groups"
    echo "└────────────────────────────────────────"
    echo ""
}

# Validate username format (POSIX compliant)
validate_username() {
    local username="$1"
    
    # Check length (1-32 characters)
    if [ ${#username} -lt 1 ] || [ ${#username} -gt 32 ]; then
        echo "ERROR: Username must be 1-32 characters long."
        return 1
    fi
    
    # Check format: lowercase letters, digits, underscore, hyphen
    # Must start with lowercase letter or underscore
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "ERROR: Invalid username format."
        echo "Username must start with lowercase letter or underscore,"
        echo "and contain only lowercase letters, digits, underscore, or hyphen."
        return 1
    fi
    
    return 0
}

# Validate group name format
validate_groupname() {
    local groupname="$1"
    
    if [ ${#groupname} -lt 1 ] || [ ${#groupname} -gt 32 ]; then
        echo "ERROR: Group name must be 1-32 characters long."
        return 1
    fi
    
    if ! [[ "$groupname" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
        echo "ERROR: Invalid group name format."
        return 1
    fi
    
    return 0
}

# Validate shell path
validate_shell() {
    local shell_path="$1"
    
    # Check if shell exists and is executable
    if [ ! -f "$shell_path" ]; then
        echo "ERROR: Shell '$shell_path' does not exist."
        return 1
    fi
    
    if [ ! -x "$shell_path" ]; then
        echo "ERROR: Shell '$shell_path' is not executable."
        return 1
    fi
    
    # Check if shell is in /etc/shells
    if ! grep -qx "$shell_path" /etc/shells 2>/dev/null; then
        echo "WARNING: Shell '$shell_path' is not listed in /etc/shells."
        read -p "Continue anyway? (y/n): " -r confirm
        if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
            return 1
        fi
    fi
    
    return 0
}

#===============================================================================
# 1. Create User
#===============================================================================
create_user(){
    echo "=========================================="
    echo "         CREATE NEW USER"
    echo "=========================================="
    
    # Get and validate username
    local username
    while true; do
        read -p "Enter new username: " -r username
        username=$(echo "$username" | xargs)  # Trim whitespace
        
        if [ -z "$username" ]; then
            echo "ERROR: Username cannot be empty."
            continue
        fi
        
        if ! validate_username "$username"; then
            continue
        fi
        
        # Check if user already exists
        if id "$username" &>/dev/null; then
            echo "ERROR: User '$username' already exists."
            continue
        fi
        
        break
    done
    
    # Get full name (optional)
    local fullname
    read -p "Enter full name (optional): " -r fullname
    
    # Create user with home directory
    local error_msg
    if [ -n "$fullname" ]; then
        if ! error_msg=$(useradd -m -s /bin/bash -c "$fullname" "$username" 2>&1); then
            echo "ERROR: Failed to create user '$username'."
            echo "Details: $error_msg"
            log_action "FAILED: User creation for '$username' - $error_msg"
            pause_prompt
            return 1
        fi
    else
        if ! error_msg=$(useradd -m -s /bin/bash "$username" 2>&1); then
            echo "ERROR: Failed to create user '$username'."
            echo "Details: $error_msg"
            log_action "FAILED: User creation for '$username' - $error_msg"
            pause_prompt
            return 1
        fi
    fi
    
    log_action "SUCCESS: Created user '$username'"
    echo "SUCCESS: User '$username' created successfully."
    
    # Set password
    echo ""
    echo "Now set a password for user '$username':"
    local passwd_attempts=0
    while [ $passwd_attempts -lt 3 ]; do
        if passwd "$username"; then
            log_action "SUCCESS: Password set for user '$username'"
            echo "SUCCESS: Password set successfully."
            break
        else
            passwd_attempts=$((passwd_attempts + 1))
            echo "WARNING: Password setup failed (attempt $passwd_attempts/3)."
            log_action "WARNING: Password set failed for '$username' (attempt $passwd_attempts)"
            
            if [ $passwd_attempts -ge 3 ]; then
                echo "ERROR: Maximum password attempts reached."
                echo "User created but password not set. Use 'passwd $username' to set it later."
                log_action "ERROR: Password not set for '$username' after 3 attempts"
            fi
        fi
    done
    
    pause_prompt
}

#===============================================================================
# 2. Delete User
#===============================================================================
delete_user(){
    echo "=========================================="
    echo "         DELETE USER"
    echo "=========================================="
    
    # Display available users
    display_user_list
    
    # Get username
    local username
    read -p "Enter username to delete: " -r username
    username=$(echo "$username" | xargs)
    
    if [ -z "$username" ]; then
        echo "ERROR: Username cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist."
        pause_prompt
        return 1
    fi
    
    # Show user details
    display_user_details "$username"
    
    # Confirmation
    echo "WARNING: This will permanently delete user '$username' and their home directory."
    read -p "Are you sure you want to continue? (yes/no): " -r confirm
    
    if ! [[ "$confirm" == "yes" ]]; then
        echo "Operation cancelled."
        log_action "CANCELLED: User deletion for '$username'"
        pause_prompt
        return 0
    fi
    
    # Create backup directory if it doesn't exist
    if ! mkdir -p "$BACKUP_DIR" 2>/dev/null; then
        echo "WARNING: Could not create backup directory '$BACKUP_DIR'."
        read -p "Continue without backup? (y/n): " -r continue_no_backup
        if ! [[ "$continue_no_backup" =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            pause_prompt
            return 1
        fi
    fi
    
    # Backup home directory if it exists
    local home_dir
    home_dir=$(getent passwd "$username" | cut -d: -f6)
    
    if [ -d "$home_dir" ] && [ -w "$BACKUP_DIR" ]; then
        local backup_file="$BACKUP_DIR/${username}_$(date +%Y%m%d_%H%M%S).tar.gz"
        echo "Backing up home directory to: $backup_file"
        
        if tar -czf "$backup_file" -C "$(dirname "$home_dir")" "$(basename "$home_dir")" 2>/dev/null; then
            log_action "SUCCESS: Backed up '$home_dir' to '$backup_file'"
            echo "SUCCESS: Backup created successfully."
        else
            echo "WARNING: Backup failed, but will continue with deletion."
            log_action "WARNING: Backup failed for '$username'"
        fi
    fi
    
    # Delete user and home directory
    local error_msg
    if error_msg=$(userdel -r "$username" 2>&1); then
        log_action "SUCCESS: Deleted user '$username' with home directory"
        echo "SUCCESS: User '$username' deleted successfully."
    else
        echo "ERROR: Failed to delete user '$username'."
        echo "Details: $error_msg"
        log_action "FAILED: User deletion for '$username' - $error_msg"
    fi
    
    pause_prompt
}

#===============================================================================
# 3. Modify User
#===============================================================================
modify_user() {
    echo "=========================================="
    echo "         MODIFY USER"
    echo "=========================================="
    
    # Display available users
    display_user_list
    
    # Get username
    local username
    read -p "Enter username to modify: " -r username
    username=$(echo "$username" | xargs)
    
    if [ -z "$username" ]; then
        echo "ERROR: Username cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist."
        pause_prompt
        return 1
    fi
    
    # Modification menu
    while true; do
        clear
        echo "=========================================="
        echo "   MODIFY USER: $username"
        echo "=========================================="
        
        # Show current user details
        display_user_details "$username"
        
        echo "MODIFICATION OPTIONS:"
        echo "  1) Change Password"
        echo "  2) Change Shell"
        echo "  3) Change Full Name"
        echo "  4) Change Home Directory"
        echo "  5) Return to Main Menu"
        echo "=========================================="
        read -p "Select option [1-5]: " -r mod_choice
        
        case "$mod_choice" in
            1)
                echo "Changing password for '$username'..."
                if passwd "$username"; then
                    log_action "SUCCESS: Password changed for '$username'"
                    echo "SUCCESS: Password changed."
                else
                    echo "ERROR: Password change failed."
                    log_action "FAILED: Password change for '$username'"
                fi
                pause_prompt
                ;;
            2)
                local new_shell
                echo "Common shells: /bin/bash, /bin/sh, /bin/zsh, /bin/dash"
                read -p "Enter new shell path: " -r new_shell
                new_shell=$(echo "$new_shell" | xargs)
                
                if [ -z "$new_shell" ]; then
                    echo "ERROR: Shell path cannot be empty."
                    pause_prompt
                    continue
                fi
                
                if validate_shell "$new_shell"; then
                    local error_msg
                    if error_msg=$(usermod -s "$new_shell" "$username" 2>&1); then
                        log_action "SUCCESS: Changed shell for '$username' to '$new_shell'"
                        echo "SUCCESS: Shell changed to '$new_shell'."
                    else
                        echo "ERROR: Failed to change shell."
                        echo "Details: $error_msg"
                        log_action "FAILED: Shell change for '$username' - $error_msg"
                    fi
                fi
                pause_prompt
                ;;
            3)
                local new_name
                read -p "Enter new full name: " -r new_name
                
                local error_msg
                if error_msg=$(usermod -c "$new_name" "$username" 2>&1); then
                    log_action "SUCCESS: Changed full name for '$username' to '$new_name'"
                    echo "SUCCESS: Full name changed."
                else
                    echo "ERROR: Failed to change full name."
                    echo "Details: $error_msg"
                    log_action "FAILED: Name change for '$username' - $error_msg"
                fi
                pause_prompt
                ;;
            4)
                local new_home
                read -p "Enter new home directory path: " -r new_home
                new_home=$(echo "$new_home" | xargs)
                if [ -z "$new_home" ]; then
                    echo "ERROR: Home directory path cannot be empty."
                    pause_prompt
                    continue
                fi
		# Get current home directory for the user
		local current_home
		current_home=$(getent passwd "$username" | cut -d: -f6)
		echo "Current home directory: $current_home"

		# Check if trying to set same directory
		if [ "$new_home" = "$current_home" ]; then
   			 echo "ERROR: New home directory is the same as current home directory."
   			 echo "No changes needed."
   			 pause_prompt
   			 continue
		fi
                read -p "Move existing contents? (y/n): " -r move_contents
                local move_flag=""
                if [[ "$move_contents" =~ ^[Yy]$ ]]; then
                    move_flag="-m"
                fi
                
                local error_msg
                if error_msg=$(usermod $move_flag -d "$new_home" "$username" 2>&1); then
                    log_action "SUCCESS: Changed home directory for '$username' to '$new_home'"
                    echo "SUCCESS: Home directory changed."
                else
                    echo "ERROR: Failed to change home directory."
                    echo "Details: $error_msg"
                    log_action "FAILED: Home directory change for '$username' - $error_msg"
                fi
                pause_prompt
                ;;
            5)
                return 0
                ;;
            *)
                echo "ERROR: Invalid option. Please select 1-5."
                pause_prompt
                ;;
        esac
    done
}

#===============================================================================
# 4. List Users
#===============================================================================
list_users() {
    echo "=========================================="
    echo "         SYSTEM USERS"
    echo "=========================================="
    
    printf "%-20s | %-6s | %-30s | %-20s\n" "Username" "UID" "Home Directory" "Shell"
    echo "------------------------------------------------------------------------------------------------"
    
    # List users with UID >= 1000 (regular users), excluding 'nobody'
    awk -F: '($3 >= 1000 && $1 != "nobody") {
        printf "%-20s | %-6s | %-30s | %-20s\n", $1, $3, $6, $7
    }' /etc/passwd | sort
    
    echo "------------------------------------------------------------------------------------------------"
    
    # Count users
    local user_count
    user_count=$(awk -F: '($3 >= 1000 && $1 != "nobody") {print}' /etc/passwd | wc -l)
    echo "Total regular users: $user_count"
    
    pause_prompt
}

#===============================================================================
# 5. Lock User Account
#===============================================================================
lock_user(){
    echo "=========================================="
    echo "         LOCK USER ACCOUNT"
    echo "=========================================="
    
    # Display available users
    display_user_list
    
    local username
    read -p "Enter username to lock: " -r username
    username=$(echo "$username" | xargs)
    
    if [ -z "$username" ]; then
        echo "ERROR: Username cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist."
        pause_prompt
        return 1
    fi
    
    # Show user details
    display_user_details "$username"
    
    # Check if already locked
    if passwd -S "$username" 2>/dev/null | grep -q " L "; then
        echo "WARNING: User '$username' is already locked."
        pause_prompt
        return 0
    fi
    
    # Confirmation
    read -p "Lock this account? (y/n): " -r confirm
    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        pause_prompt
        return 0
    fi
    
    local error_msg
    if error_msg=$(usermod -L "$username" 2>&1); then
        log_action "SUCCESS: Locked account for '$username'"
        echo "SUCCESS: User account '$username' locked."
    else
        echo "ERROR: Failed to lock user account."
        echo "Details: $error_msg"
        log_action "FAILED: Account lock for '$username' - $error_msg"
    fi
    
    pause_prompt
}

#===============================================================================
# 6. Unlock User Account
#===============================================================================
unlock_user(){
    echo "=========================================="
    echo "         UNLOCK USER ACCOUNT"
    echo "=========================================="
    
    # Display available users
    display_user_list
    
    local username
    read -p "Enter username to unlock: " -r username
    username=$(echo "$username" | xargs)
    
    if [ -z "$username" ]; then
        echo "ERROR: Username cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist."
        pause_prompt
        return 1
    fi
    
    # Show user details
    display_user_details "$username"
    
    # Check if already unlocked
    if passwd -S "$username" 2>/dev/null | grep -q " P "; then
        echo "WARNING: User '$username' is already unlocked."
        pause_prompt
        return 0
    fi
    
    # Confirmation
    read -p "Unlock this account? (y/n): " -r confirm
    if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "Operation cancelled."
        pause_prompt
        return 0
    fi
    
    local error_msg
    if error_msg=$(usermod -U "$username" 2>&1); then
        log_action "SUCCESS: Unlocked account for '$username'"
        echo "SUCCESS: User account '$username' unlocked."
    else
        echo "ERROR: Failed to unlock user account."
        echo "Details: $error_msg"
        log_action "FAILED: Account unlock for '$username' - $error_msg"
    fi
    
    pause_prompt
}

#===============================================================================
# 7. Create Group
#===============================================================================
create_group(){
    echo "=========================================="
    echo "         CREATE NEW GROUP"
    echo "=========================================="
    
    local groupname
    while true; do
        read -p "Enter new group name: " -r groupname
        groupname=$(echo "$groupname" | xargs)
        
        if [ -z "$groupname" ]; then
            echo "ERROR: Group name cannot be empty."
            continue
        fi
        
        if ! validate_groupname "$groupname"; then
            continue
        fi
        
        # Check if group already exists
        if getent group "$groupname" &>/dev/null; then
            echo "ERROR: Group '$groupname' already exists."
            continue
        fi
        
        break
    done
    
    local error_msg
    if error_msg=$(groupadd "$groupname" 2>&1); then
        log_action "SUCCESS: Created group '$groupname'"
        echo "SUCCESS: Group '$groupname' created successfully."
    else
        echo "ERROR: Failed to create group."
        echo "Details: $error_msg"
        log_action "FAILED: Group creation for '$groupname' - $error_msg"
    fi
    
    pause_prompt
}

#===============================================================================
# 8. Delete Group
#===============================================================================
delete_group(){
    echo "=========================================="
    echo "         DELETE GROUP"
    echo "=========================================="
    
    # Display available groups
    display_group_list
    
    local groupname
    read -p "Enter group name to delete: " -r groupname
    groupname=$(echo "$groupname" | xargs)
    
    if [ -z "$groupname" ]; then
        echo "ERROR: Group name cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if group exists
    if ! getent group "$groupname" &>/dev/null; then
        echo "ERROR: Group '$groupname' does not exist."
        pause_prompt
        return 1
    fi
    
    # Warn if group is a primary group for any user
    local users_with_group
    users_with_group=$(awk -F: -v gid="$(getent group "$groupname" | cut -d: -f3)" '$4 == gid {print $1}' /etc/passwd)
    
    if [ -n "$users_with_group" ]; then
        echo ""
        echo "WARNING: This group is the primary group for the following users:"
        echo "$users_with_group"
        echo "Deleting this group may cause issues. Consider changing their primary group first."
        read -p "Continue anyway? (yes/no): " -r confirm
        if ! [[ "$confirm" == "yes" ]]; then
            echo "Operation cancelled."
            pause_prompt
            return 0
        fi
    else
        read -p "Delete group '$groupname'? (y/n): " -r confirm
        if ! [[ "$confirm" =~ ^[Yy]$ ]]; then
            echo "Operation cancelled."
            pause_prompt
            return 0
        fi
    fi
    
    local error_msg
    if error_msg=$(groupdel "$groupname" 2>&1); then
        log_action "SUCCESS: Deleted group '$groupname'"
        echo "SUCCESS: Group '$groupname' deleted successfully."
    else
        echo "ERROR: Failed to delete group."
        echo "Details: $error_msg"
        log_action "FAILED: Group deletion for '$groupname' - $error_msg"
    fi
    
    pause_prompt
}

#===============================================================================
# 9. Add User to Group
#===============================================================================
add_user_group() {
    echo "=========================================="
    echo "         ADD USER TO GROUP"
    echo "=========================================="
    
    # Display available users
    display_user_list
    
    local username
    read -p "Enter username: " -r username
    username=$(echo "$username" | xargs)
    
    if [ -z "$username" ]; then
        echo "ERROR: Username cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if user exists
    if ! id "$username" &>/dev/null; then
        echo "ERROR: User '$username' does not exist."
        pause_prompt
        return 1
    fi
    
    # Display available groups
    display_group_list
    
    local groupname
    read -p "Enter group name: " -r groupname
    groupname=$(echo "$groupname" | xargs)
    
    if [ -z "$groupname" ]; then
        echo "ERROR: Group name cannot be empty."
        pause_prompt
        return 1
    fi
    
    # Check if group exists
    if ! getent group "$groupname" &>/dev/null; then
        echo "ERROR: Group '$groupname' does not exist."
        pause_prompt
        return 1
    fi
    
    # Check if user is already in group
    if groups "$username" 2>/dev/null | grep -qw "$groupname"; then
        echo "WARNING: User '$username' is already a member of group '$groupname'."
        pause_prompt
        return 0
    fi
    
    local error_msg
    if error_msg=$(usermod -aG "$groupname" "$username" 2>&1); then
        log_action "SUCCESS: Added '$username' to group '$groupname'"
        echo "SUCCESS: User '$username' added to group '$groupname'."
        
        # Show updated groups
        echo ""
        echo "Updated groups for '$username':"
        groups "$username"
    else
        echo "ERROR: Failed to add user to group."
        echo "Details: $error_msg"
        log_action "FAILED: Adding '$username' to group '$groupname' - $error_msg"
    fi
    
    pause_prompt
}

#===============================================================================
# 10. Batch Process CSV File
#===============================================================================
process_user_file() {
    local input_file="$1"
    local line_num=0
    local success_count=0
    local error_count=0

    echo "=========================================="
    echo "   BATCH USER CREATION"
    echo "=========================================="
    echo "Processing file: $input_file"
    echo ""

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        
        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # Parse CSV line
        IFS=',' read -r username rest <<< "$line"
        username=$(echo "$username" | xargs)
        
        # Validate username
        if [ -z "$username" ]; then
            echo "Line $line_num: ERROR - Missing username"
            error_count=$((error_count + 1))
            continue
        fi
        
        if ! validate_username "$username"; then
            echo "Line $line_num: ERROR - Invalid username '$username'"
            error_count=$((error_count + 1))
            continue
        fi

        # Check if user already exists
        if id "$username" &>/dev/null; then
            echo "Line $line_num: User '$username' already exists, skipping creation"
        else
            # Create user
            if useradd -m -s /bin/bash "$username" 2>/dev/null; then
                # Lock account initially for security
                passwd -l "$username" &>/dev/null
                log_action "BATCH: Created user '$username'"
                echo "Line $line_num: Created user '$username'"
                success_count=$((success_count + 1))
            else
                echo "Line $line_num: ERROR - Failed to create user '$username'"
                error_count=$((error_count + 1))
                continue
            fi
        fi

        # Process groups
        if [ -n "$rest" ]; then
            IFS=',' read -ra group_array <<< "$rest"
            
            for group in "${group_array[@]}"; do
                group=$(echo "$group" | xargs)
                [ -z "$group" ] && continue

                # Validate group name
                if ! validate_groupname "$group"; then
                    echo "  Line $line_num: WARNING - Invalid group name '$group', skipping"
                    continue
                fi

                # Create group if it doesn't exist
                if ! getent group "$group" &>/dev/null; then
                    if groupadd "$group" 2>/dev/null; then
                        log_action "BATCH: Created group '$group'"
                        echo "  Created group '$group'"
                    else
                        echo "  Line $line_num: WARNING - Failed to create group '$group'"
                        continue
                    fi
                fi

                # Add user to group
                if usermod -aG "$group" "$username" 2>/dev/null; then
                    echo "  Added '$username' to group '$group'"
                else
                    echo "  Line $line_num: WARNING - Failed to add '$username' to group '$group'"
                fi
            done
        fi

    done < "$input_file"

    echo ""
    echo "=========================================="
    echo "   BATCH PROCESS COMPLETE"
    echo "=========================================="
    echo "Total lines processed: $line_num"
    echo "Successful operations: $success_count"
    echo "Errors encountered: $error_count"
    echo "=========================================="
    
    log_action "BATCH: Completed processing '$input_file' - Success: $success_count, Errors: $error_count"
}

#===============================================================================
# Batch Mode Handler
#===============================================================================
batch_process(){
    local input_file=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            -f|--file)
                if [ -z "${2:-}" ]; then
                    echo "ERROR: --file option requires a filename argument"
                    exit 1
                fi
                input_file="$2"
                shift 2
                ;;
            -h|--help)
                echo "Usage: $SCRIPT_NAME [OPTIONS]"
                echo ""
                echo "OPTIONS:"
                echo "  -f, --file FILE    Process users from CSV file (batch mode)"
                echo "  -h, --help         Display this help message"
                echo ""
                echo "CSV Format: username,group1,group2,..."
                echo "Example: john,developers,admin"
                exit 0
                ;;
            *)
                echo "ERROR: Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    if [ -z "$input_file" ]; then
        echo "ERROR: --file option is required for batch mode"
        exit 1
    fi

    if [ ! -f "$input_file" ]; then
        echo "ERROR: File '$input_file' does not exist"
        exit 1
    fi

    if [ ! -r "$input_file" ]; then
        echo "ERROR: File '$input_file' is not readable"
        exit 1
    fi

    process_user_file "$input_file"
}

#===============================================================================
# Main Menu
#===============================================================================
main_menu(){
    while true; do
        clear
        echo "=========================================="
        echo "   USER & GROUP MANAGEMENT SYSTEM"
        echo "=========================================="
        echo "   System Programming Course Project"
        echo "=========================================="
        echo ""
        echo "USER MANAGEMENT:"
        echo "  1) Create User"
        echo "  2) Delete User"
        echo "  3) Modify User"
        echo "  4) List Users"
        echo "  5) Lock User Account"
        echo "  6) Unlock User Account"
        echo ""
        echo "GROUP MANAGEMENT:"
        echo "  7) Create Group"
        echo "  8) Delete Group"
        echo "  9) Add User to Group"
        echo ""
        echo "  0) Exit"
        echo "=========================================="
        read -p "Enter your choice [0-9]: " -r choice

        case "$choice" in
            1) create_user ;;
            2) delete_user ;;
            3) modify_user ;;
            4) list_users ;;
            5) lock_user ;;
            6) unlock_user ;;
            7) create_group ;;
            8) delete_group ;;
            9) add_user_group ;;
            0) 
                log_action "Script terminated by user"
                echo "Exiting... Goodbye!"
                exit 0
                ;;
            *)
                echo "ERROR: Invalid option. Please select 0-9."
                pause_prompt
                ;;
        esac
    done
}

#===============================================================================
# Main Execution
#===============================================================================
log_action "Script started by user $(whoami)"

# Check if running in batch mode or interactive mode
if [ $# -gt 0 ]; then
    batch_process "$@"
else
    main_menu
fi
