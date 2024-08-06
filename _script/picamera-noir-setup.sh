#!/bin/bash

################################################################################
# Pi Camera NoIR Setup Script for Raspberry Pi Zero W
#
# This script installs and configures a lightweight surveillance camera system
# on a Raspberry Pi Zero W. It sets up Lighttpd, PHP, and a Flask application
# with Gunicorn for streaming video from the Pi NoIR camera. It also includes
# scripts for controlling system shutdown and reboot via the web interface.
#
# Features:
# - Video streaming using Flask and Gunicorn
# - Lighttpd web server with PHP support
# - Systemd service for reliable Flask app management
# - Bootstrap-based web interface for easy control
# - Dark mode support based on system theme
#
# Usage:
# Make the script executable: chmod +x prepare-picamera-noir.sh
# Run the script: ./prepare-picamera-noir.sh
#
# After setup, access the surveillance camera at:
# http://<RaspberryPi_IP>/surveillance/index.html
#
# Copyright (c) 2024 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

# Exit immediately if a command exits with a non-zero status
set -e

# Function to display messages in green color
print_green() {
    echo -e "\e[32m$1\e[0m"
}

# Function to display error messages in red color
print_red() {
    echo -e "\e[31m$1\e[0m"
}

# Function to check command execution and handle errors
run_command() {
    if ! $1; then
        print_red "Error: Failed to execute: $1"
        exit 1
    fi
}

print_green "Updating the system..."
run_command "sudo apt update && sudo apt upgrade -y"

print_green "Installing required packages..."
run_command "sudo apt install -y lighttpd php php-cgi python3-picamera python3-flask python3-gunicorn"

print_green "Enabling PHP in lighttpd..."
run_command "sudo lighty-enable-mod fastcgi-php"
run_command "sudo service lighttpd restart"

# Directory for web files
PROJECT_DIR="/var/www/html/surveillance"

print_green "Creating project directory: $PROJECT_DIR"
sudo mkdir -p $PROJECT_DIR

# Flask application for camera streaming
print_green "Setting up Flask application for camera streaming..."
cat << EOF | sudo tee $PROJECT_DIR/camera_stream.py > /dev/null
from flask import Flask, Response
import io
import picamera
from threading import Condition

app = Flask(__name__)
output = None

class StreamingOutput:
    def __init__(self):
        self.frame = None
        self.buffer = io.BytesIO()
        self.condition = Condition()

    def write(self, buf):
        if buf.startswith(b'\xff\xd8'):
            self.buffer.truncate()
            with self.condition:
                self.frame = self.buffer.getvalue()
                self.condition.notify_all()
            self.buffer.seek(0)
        return self.buffer.write(buf)

@app.route('/stream.mjpg')
def stream_video():
    def generate():
        while True:
            with output.condition:
                output.condition.wait()
                frame = output.frame
            yield (b'--FRAME\r\n'
                   b'Content-Type: image/jpeg\r\n'
                   b'Content-Length: %d\r\n\r\n' % len(frame) + frame + b'\r\n')

    return Response(generate(), mimetype='multipart/x-mixed-replace; boundary=FRAME')

def main():
    global output
    with picamera.PiCamera(resolution='640x480', framerate=24) as camera:
        output = StreamingOutput()
        camera.start_recording(output, format='mjpeg')
        try:
            app.run(host='0.0.0.0', port=8080, threaded=True)
        finally:
            camera.stop_recording()

if __name__ == '__main__':
    main()
EOF

# Make Flask script executable
run_command "sudo chmod +x $PROJECT_DIR/camera_stream.py"

# Create systemd service for Flask application
print_green "Creating systemd service for Flask application..."
cat << EOF | sudo tee /etc/systemd/system/camera_stream.service > /dev/null
[Unit]
Description=Camera Streaming Service
After=network.target

[Service]
ExecStart=/usr/bin/gunicorn -w 1 -b 0.0.0.0:8080 camera_stream:app
WorkingDirectory=$PROJECT_DIR
Restart=always
User=pi

[Install]
WantedBy=multi-user.target
EOF

# Enable and start the camera streaming service
run_command "sudo systemctl enable camera_stream.service"
run_command "sudo systemctl start camera_stream.service"

# PHP scripts for shutdown and reboot
print_green "Creating shutdown.php..."
cat << 'EOF' | sudo tee $PROJECT_DIR/shutdown.php > /dev/null
<?php
shell_exec('sudo shutdown -h now');
echo 'Shutting down...';
?>
EOF

print_green "Creating reboot.php..."
cat << 'EOF' | sudo tee $PROJECT_DIR/reboot.php > /dev/null
<?php
shell_exec('sudo reboot');
echo 'Rebooting...';
?>
EOF

# HTML frontend
print_green "Creating index.html..."
cat << 'EOF' | sudo tee $PROJECT_DIR/index.html > /dev/null
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Raspberry Pi - Surveillance Camera</title>
    <link rel="icon" type="image/x-icon" href="/favicon.ico">
    <link href="bootstrap-5.3.3-dist/css/bootstrap.min.css" rel="stylesheet">
    <link rel="stylesheet" type="text/css" href="styles.css">
</head>
<body class="bg-light">
    <div class="container-fluid p-0">
        <div id="video-container" class="position-relative w-100 h-100">
            <img id="stream" src="http://localhost:8080/stream.mjpg" class="img-fluid w-100 h-100" alt="Surveillance Stream">
            <div id="video-overlay" class="position-absolute top-0 end-0 p-3">
                <div id="buttons" class="btn-group">
                    <button id="shutdown" type="button" class="btn btn-danger">Shutdown</button>
                    <button id="reboot" type="button" class="btn btn-warning">Reboot</button>
                    <button id="fullscreen" type="button" class="btn btn-primary">Fullscreen</button>
                </div>
            </div>
        </div>
    </div>

    <script src="bootstrap-5.3.3-dist/js/bootstrap.bundle.min.js"></script>
    <script src="pi_camera_controls.js"></script>
</body>
</html>
EOF

# JavaScript for camera controls
print_green "Creating pi_camera_controls.js..."
cat << 'EOF' | sudo tee $PROJECT_DIR/pi_camera_controls.js > /dev/null
document.addEventListener("DOMContentLoaded", function () {
    const videoContainer = document.getElementById("video-container");
    const fullscreenButton = document.getElementById("fullscreen");
    const shutdownButton = document.getElementById("shutdown");
    const rebootButton = document.getElementById("reboot");
    const buttonsContainer = document.getElementById("buttons");

    function prefersDarkTheme() {
        return window.matchMedia('(prefers-color-scheme: dark)').matches;
    }

    function applyBackground() {
        document.body.classList.toggle("dark-theme", prefersDarkTheme());
    }

    applyBackground();

    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', applyBackground);

    fullscreenButton.addEventListener("click", function () {
        if (document.fullscreenElement) {
            document.exitFullscreen();
        } else {
            videoContainer.requestFullscreen();
        }
    });

    shutdownButton.addEventListener("click", function () {
        if (confirm('Are you sure you want to shutdown the system?')) {
            fetch('/shutdown.php', { method: 'POST' })
                .then(response => response.ok ? console.log('Shutdown request sent') : console.error('Shutdown request failed:', response.statusText))
                .catch(error => console.error('Error sending shutdown request:', error));
        }
    });

    rebootButton.addEventListener("click", function () {
        if (confirm('Are you sure you want to reboot the system?')) {
            fetch('/reboot.php', { method: 'POST' })
                .then(response => response.ok ? console.log('Reboot request sent') : console.error('Reboot request failed:', response.statusText))
                .catch(error => console.error('Error sending reboot request:', error));
        }
    });

    document.addEventListener("fullscreenchange", function () {
        buttonsContainer.classList.toggle("fullscreen", document.fullscreenElement === videoContainer);
    });
});
EOF

# CSS stylesheet
print_green "Creating styles.css..."
cat << 'EOF' | sudo tee $PROJECT_DIR/styles.css > /dev/null
body, html {
    margin: 0;
    padding: 0;
    height: 100%;
    overflow: hidden;
}

body.dark-theme {
    background-color: #333;
    color: #fff;
}

#video-container {
    overflow: hidden;
}

#stream {
    object-fit: cover;
    cursor: pointer;
}

#video-overlay {
    pointer-events: none;
}

#buttons {
    pointer-events: auto;
}

.btn {
    opacity: 0.8;
    transition: opacity 0.3s;
}

.btn:hover {
    opacity: 1;
}

.fullscreen {
    position: fixed;
    top: 10px;
    right: 10px;
}

@media (max-width: 600px) {
    #buttons {
        flex-direction: column;
    }

    #buttons .btn {
        margin-bottom: 5px;
    }
}
EOF

# Permissions for shutdown and reboot
print_green "Configuring permissions for shutdown and reboot..."
run_command "sudo bash -c 'echo \"www-data ALL=(ALL) NOPASSWD: /sbin/shutdown\" >> /etc/sudoers'"
run_command "sudo bash -c 'echo \"www-data ALL=(ALL) NOPASSWD: /sbin/reboot\" >> /etc/sudoers'"

# Fetching the Raspberry Pi IP address
PI_IP=$(hostname -I | awk '{print $1}')

print_green "Setup complete! Access the surveillance camera at: http://${PI_IP}/surveillance/index.html"
