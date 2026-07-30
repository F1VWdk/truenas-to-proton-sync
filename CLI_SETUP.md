# Proton Drive CLI Setup & Authentication

To run the TrueNAS sync script, you need to download the official Proton Drive CLI binary, securely store your credentials, and configure the included wrapper script.

Because the Proton Drive CLI is not part of the TrueNAS OS, it must be downloaded and placed in a directory (like your user home folder) where OS updates will not wipe it out.

### 1. Download the Binary
Create a directory to hold the executable and your sensitive session data. Keep this outside the main repository folder to prevent accidentally committing the binary or your credentials.

```bash
mkdir ~/proton-drive-cli
cd ~/proton-drive-cli
wget https://proton.me/download/drive/cli/0.6.0/linux-x64/proton-drive
chmod +x proton-drive
```

### 2. Create the Secure Session Folder
This directory stores your authentication token. It must be created and locked down before you attempt to log in.

```bash
mkdir ~/proton-drive-cli/session
chmod 700 ~/proton-drive-cli/session
```

### 3. Update the Wrapper Script
The `proton-drive-cli-sync` wrapper script is already included in this repository. Open it and ensure the absolute paths point correctly to your TrueNAS data pool and user folder. 

```bash
nano proton-drive-cli-sync
```

Verify these lines match your environment:
```bash
export PROTON_DRIVE_CACHE_DIR="/mnt/YOURPOOL/home/YOURFOLDER/proton-drive-cli/session"
exec "/mnt/YOURPOOL/home/YOURFOLDER/proton-drive-cli/proton-drive" "$@"
```

### 4. Authenticate
From inside the repository folder, run the wrapper script to initiate the login process.

```bash
./proton-drive-cli-sync auth login
```
Copy the provided URL and paste it into a web browser. Once you log in on the browser, the terminal session will automatically receive the response and proceed on its own.

### 5. Verify the Connection
Test your setup by listing the files in your root Proton Drive directory. 

```bash
./proton-drive-cli-sync filesystem list /
```

If the response shows the list of your files, the CLI is successfully configured, remembers your credentials, and can be called by the script!
