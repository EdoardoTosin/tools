#!/bin/bash

################################################################################
# Raspberry Pi DNS Server
#
# Setup a Raspberry Pi as an authoritative DNS server with a web interface for
# managing DNS entries. The setup includes configuring dnsmasq for DNS
# resolution and setting up a Flask web application for DNS entry management.
#
# Copyright (c) 2024 Edoardo Tosin
#
# This file is licensed under the terms of the MIT License.
# This program is licensed "as is" without any warranty of any kind, whether
# express or implied.
#
################################################################################

# Configuration directory and file paths
CONFIG_DIR="$HOME/.dns_web_interface"
CONFIG_FILE="$CONFIG_DIR/credentials.conf"

# Function to print error messages and exit
function error_exit {
    echo "$1" 1>&2
    exit 1
}

# Function to read credentials from configuration file
function read_credentials {
    if [ -f "$CONFIG_FILE" ]; then
        source "$CONFIG_FILE"
    else
        echo "ADMIN_USERNAME=admin" > "$CONFIG_FILE"
        echo "ADMIN_PASSWORD=password123" >> "$CONFIG_FILE"
        source "$CONFIG_FILE"
    fi
}

# Ensure the directory for configuration files exists
if [ ! -d "$CONFIG_DIR" ]; then
    echo "Creating configuration directory: $CONFIG_DIR"
    mkdir -p "$CONFIG_DIR" || error_exit "Failed to create directory $CONFIG_DIR"
else
    echo "Configuration directory already exists: $CONFIG_DIR"
fi

# Read credentials from configuration file
echo "Reading credentials from configuration file..."
read_credentials

# Reload systemd after creating the service file
function reload_systemd {
    echo "Reloading systemd..."
    sudo systemctl daemon-reload || error_exit "Failed to reload systemd."
}

# Reload systemd
reload_systemd

# Update and upgrade the system
echo "Updating and upgrading the system..."
sudo apt update && sudo apt upgrade -y || error_exit "System update/upgrade failed."

# Install dnsmasq
echo "Installing dnsmasq..."
sudo apt install -y dnsmasq || error_exit "Failed to install dnsmasq."

# Backup the original dnsmasq configuration file
if [ -f /etc/dnsmasq.conf ]; then
    echo "Backing up the original dnsmasq configuration..."
    sudo cp /etc/dnsmasq.conf /etc/dnsmasq.conf.bak || error_exit "Failed to backup dnsmasq configuration."
else
    echo "Original dnsmasq configuration not found."
fi

# Get the hostname and IP address of the Raspberry Pi
echo "Getting hostname and IP address..."
RPI_HOSTNAME=$(hostname)
RPI_IP=$(hostname -I | awk '{print $1}')
echo "Hostname: $RPI_HOSTNAME"
echo "IP Address: $RPI_IP"

# Configure dnsmasq
echo "Configuring dnsmasq..."
sudo tee /etc/dnsmasq.conf > /dev/null <<EOL
# Set the domain
domain=local

# Enable authoritative DNS for .local domain
auth-server=${RPI_HOSTNAME}.local,${RPI_IP}
auth-zone=local
auth-peer=${RPI_IP}

# Specify to handle only .local domain
local=/local/

# Log queries
log-queries
log-facility=/var/log/dnsmasq/dnsmasq.log
EOL

# Configure static host entries
echo "Configuring static host entries..."
if ! grep -q "${RPI_HOSTNAME}.local" /etc/hosts; then
    echo "Adding static host entry to /etc/hosts..."
    echo "${RPI_IP} ${RPI_HOSTNAME}.local ${RPI_HOSTNAME}" | sudo tee -a /etc/hosts
else
    echo "Static host entry already exists in /etc/hosts."
fi

# Create a directory for dnsmasq logs in RAM
echo "Creating directory for dnsmasq logs in RAM..."
sudo mkdir -p /var/log/dnsmasq
sudo chmod 755 /var/log/dnsmasq

# Add tmpfs entry to /etc/fstab to mount /var/log/dnsmasq in RAM
echo "Adding tmpfs entry to /etc/fstab..."
if ! grep -q "/var/log/dnsmasq" /etc/fstab; then
    echo "tmpfs /var/log/dnsmasq tmpfs defaults,noatime,nosuid,nodev,size=50M 0 0" | sudo tee -a /etc/fstab
    # Reload systemd
    reload_systemd
else
    echo "tmpfs entry already exists in /etc/fstab."
fi

# Mount the tmpfs
echo "Mounting tmpfs..."
sudo mount -a

# Ensure /etc/resolv.conf is configured correctly
echo "Setting up /etc/resolv.conf..."
sudo rm /etc/resolv.conf
sudo tee /etc/resolv.conf > /dev/null <<EOL
nameserver 1.1.1.1
nameserver 1.0.0.1
EOL

# Create the update_hosts.sh script
echo "Creating update_hosts.sh script..."
sudo tee /usr/local/bin/update_hosts.sh > /dev/null <<'EOL'
#!/bin/bash

# Function to print error messages
function error_exit {
    echo "$1" 1>&2
    exit 1
}

ACTION=$1
NAME=$2
IP=$3

case $ACTION in
    add)
        if grep -q "$NAME" /etc/hosts; then
            error_exit "Entry already exists."
        else
            echo "$IP $NAME" | sudo tee -a /etc/hosts > /dev/null
        fi
        ;;
    edit)
        if grep -q "$NAME" /etc/hosts; then
            sudo sed -i "s/^.*$NAME\$/$IP $NAME/" /etc/hosts
        else
            error_exit "Entry does not exist."
        fi
        ;;
    delete)
        if grep -q "$NAME" /etc/hosts; then
            sudo sed -i "/$NAME/d" /etc/hosts
        else
            error_exit "Entry does not exist."
        fi
        ;;
    *)
        error_exit "Invalid action. Use add, edit, or delete."
        ;;
esac
EOL

# Make the update_hosts.sh script executable
echo "Making update_hosts.sh script executable..."
sudo chmod +x /usr/local/bin/update_hosts.sh

# Configure passwordless sudo for update_hosts.sh
echo "Configuring passwordless sudo for update_hosts.sh..."
sudo tee /etc/sudoers.d/update_hosts > /dev/null <<EOL
pi ALL=(ALL) NOPASSWD: /usr/local/bin/update_hosts.sh
EOL

# Install dnsutils package for dig command
echo "Installing dnsutils package..."
sudo apt install -y dnsutils || error_exit "Failed to install dnsutils."

# Install Python and create a virtual environment
echo "Installing Python and creating a virtual environment..."
sudo apt install -y python3 python3-venv || error_exit "Failed to install Python and python3-venv."
python3 -m venv ~/dns-web-interface-venv || error_exit "Failed to create virtual environment."

# Activate the virtual environment
echo "Activating the virtual environment..."
source ~/dns-web-interface-venv/bin/activate || error_exit "Failed to activate virtual environment."

# Install Flask
echo "Installing Flask..."
pip install flask || error_exit "Failed to install Flask."

# Deactivate the virtual environment
echo "Deactivating the virtual environment..."
deactivate

# Create a directory for the Flask app
APP_DIR="$HOME/dns-web-interface"
echo "Creating directory for the Flask app: $APP_DIR"
mkdir -p "$APP_DIR" || error_exit "Failed to create directory $APP_DIR"

# Create the Flask app
echo "Creating the Flask app..."
tee $APP_DIR/app.py > /dev/null <<EOL
from flask import Flask, request, render_template, redirect, url_for, session, abort, flash
import os, subprocess

app = Flask(__name__)
app.secret_key = 'your_secret_key_here'  # Change this to a secure secret key

# Route to handle requests for '/favicon.ico' and redirect to the PNG file
@app.route('/favicon.ico')
def favicon():
    return redirect(url_for('static', filename='favicon.png'), code=301)

# Define a dictionary of valid usernames and passwords
VALID_USERS = {'admin': 'password123'}

HOSTS_FILE = '/etc/hosts'
DNSMASQ_CONF = '/etc/dnsmasq.conf'

class InvalidInputError(Exception):
    pass

def validate_input(name, ip):
    # Validate domain name and IP address
    if not name.strip() or not ip.strip():
        raise InvalidInputError("Domain name and IP address are required.")
    
    # Check if the domain name contains only alphanumeric characters, hyphens, and dots
    if not all(char.isalnum() or char in '-.' for char in name):
        raise InvalidInputError("Invalid characters in domain name.")
    
    # Check if the IP address contains four parts separated by dots, and each part is an integer in the range [0, 255]
    parts = ip.split('.')
    if len(parts) != 4 or not all(part.isdigit() and 0 <= int(part) <= 255 for part in parts):
        raise InvalidInputError("Invalid IP address format.")

def read_hosts():
    with open(HOSTS_FILE, 'r') as f:
        lines = f.readlines()
    entries = []
    for line in lines:
        parts = line.split()
        if len(parts) >= 2:
            entries.append((parts[1], parts[0]))
    return entries

def modify_hosts(action, name, ip=None):
    command = ['sudo', '/usr/local/bin/update_hosts.sh', action, name]
    if action == 'add' or action == 'edit':
        command.append(ip)
    subprocess.run(command, check=True)

@app.errorhandler(404)
def page_not_found(error):
    return render_template('404.html'), 404

@app.errorhandler(500)
def internal_server_error(error):
    return render_template('500.html'), 500

# Configuration file path
CONFIG_FILE = os.path.expanduser("~/.dns_web_interface/credentials.conf")

# Function to read credentials from configuration file
def read_credentials():
    if os.path.isfile(CONFIG_FILE):
        with open(CONFIG_FILE, 'r') as f:
            lines = f.readlines()
            credentials = {line.split('=')[0]: line.split('=')[1].strip() for line in lines}
            return credentials
    else:
        return {"ADMIN_USERNAME": "admin", "ADMIN_PASSWORD": "password123"}  # Default credentials

# Function to update credentials in memory and configuration file
def update_credentials(username, password):
    global VALID_USERS  # Access the global dictionary
    VALID_USERS = {username: password}  # Update credentials in memory
    with open(CONFIG_FILE, 'w') as f:
        f.write(f"ADMIN_USERNAME={username}\n")
        f.write(f"ADMIN_PASSWORD={password}\n")

# Route to handle requests for changing credentials
@app.route('/change_credentials', methods=['GET', 'POST'])
def change_credentials():
    if request.method == 'POST':
        new_username = request.form['username']
        new_password = request.form['password']
        update_credentials(new_username, new_password)
        flash('Credentials updated successfully', 'success')
        return redirect(url_for('index'))
    else:
        return render_template('change_credentials.html')

@app.route('/')
def index():
    # Check if the user is logged in
    if 'username' in session:
        entries = read_hosts()
        return render_template('index.html', entries=entries)
    else:
        return redirect(url_for('login'))

@app.route('/login', methods=['GET', 'POST'])
def login():
    if request.method == 'POST':
        username = request.form['username']
        password = request.form['password']
        if username in VALID_USERS and VALID_USERS[username] == password:
            session['username'] = username
            return redirect(url_for('index'))
        else:
            return render_template('login.html', error='Invalid username or password')
    else:
        return render_template('login.html', error='')

@app.route('/logout', methods=['POST'])
def logout():
    session.pop('username', None)
    return redirect(url_for('login'))

@app.route('/add', methods=['GET', 'POST'])
def add():
    if request.method == 'POST':
        name = request.form['name']
        ip = request.form['ip']
        try:
            validate_input(name, ip)
            modify_hosts('add', name, ip)
            flash('Domain added successfully', 'success')
        except InvalidInputError as e:
            return render_template('error.html', error=str(e)), 400
        except Exception as e:
            return render_template('error.html', error=str(e)), 500

        return redirect(url_for('index'))
    else:
        return render_template('add.html')

@app.route('/delete/<name>')
def delete(name):
    try:
        modify_hosts('delete', name)
    except Exception as e:
        return render_template('error.html', error=str(e)), 500

    return redirect(url_for('index'))

@app.route('/edit/<name>', methods=['GET', 'POST'])
def edit(name):
    if request.method == 'POST':
        new_name = request.form['name']
        new_ip = request.form['ip']
        try:
            validate_input(new_name, new_ip)
            modify_hosts('edit', name, new_ip)
        except InvalidInputError as e:
            return render_template('error.html', error=str(e)), 400
        except Exception as e:
            return render_template('error.html', error=str(e)), 500

        return redirect(url_for('index'))
    else:
        entries = read_hosts()
        entry = next((entry for entry in entries if entry[0] == name), None)
        if entry:
            return render_template('edit.html', entry=entry)
        else:
            abort(404)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)
EOL

FAVICON_BASE64="iVBORw0KGgoAAAANSUhEUgAAAgAAAAIACAYAAAD0eNT6AAAABHNCSVQICAgIfAhkiAAAAAlwSFlzAAAN1wAADdcBQiibeAAAABl0RVh0U29mdHdhcmUAd3d3Lmlua3NjYXBlLm9yZ5vuPBoAACAASURBVHic7J13eFRFF4ff2ZJsKimEhFASCBAgQOi9NymhKr2rKCp2UREF4bMhYkFUQBQpooDSpUiRDoJ0qdKVDqElIZByvz92UVTAZO9szbzPkyfJZuc3R9l7z7kzc84RmqahUCjcGyGEBch/21fEP34PBiyA7z++3+m1W9+FTV4D0oEbd/l+p9euAhdu+zp/+++apqU74v+DQqGQh1ABgELhOoQQJqAIEAsUs30Vxergb3fygS4y0V5S+HtwcB44ARy1fR0Dftc0LdNVBioUeR0VACgUDkQIIYBorI49lr+c/K3fiwBGF5nnarKA37EGA0f5e3BwFDilqRuUQuEwVACgUEhCCBEGlAcq3PY9Ac97encXUoA9wC5g963vmqYlu9QqhcJLUAGAQpFLhBA+QGn+7ujLA4VcaVce4iS3BQS27/s1TbvpUqsUCg9DBQAKxX8ghCgB1LZ91QLKAGaXGqX4JxnAPmAjsAHYoGnaIdeapFC4NyoAUChuw3bavhp/d/gRLjVKYS/nuS0gALao7ASF4i9UAKDI0wghooE6/OXwK6Ge7r2VDGA7fwUE6zVNO+VakxQK16ECAEWeQgjhC9QFWgItsB7SU+Rd9gBLgMXAOk3TbrjYHoXCaagAQOH1CCHisDr7FkAjIMC1FinclFTgJ6wBwRJN0w672B6FwqGoAEDhdQgh/IGGWB1+S6CESw1SeCqHsK4MLAFWaZqW5mJ7FAqpqABA4RUIIcKBjsD9WJ2/r0sNUngbN4BVwPfAbE3TLrrWHIVCPyoAUHgsNqffAegENAZMrrVIkUfIBFYCs4A5KhhQeCoqAFB4FLZqex2Aziinr3A9t4KBmViDAVWlUOExqABA4fbc5vQ7AU1QTl/hnmQCK/hrZUAFAwq3RgUACrdECGEGkoCHgOao3PwcI4xGQmNLEVG6AinnTnNyyxq7dApVq09ggWguHNjNpaMHyM5SjftyQQbwI/AFsFDTtAwX26NQ/Av1JKVwK4QQ8Vidfm8g0sXmuD1GH1+iylcjonSi7asC4SXLYbL4AbBx7HC7A4AiNRpSa+AwALJu3uDiob1cOLibCwd2cf7ALk5v30TG9VRp/y1ehhlobfs6K4SYAnyhadoB15qlUPyFCgAULseWttcJeBhrkR7FPfALzU+xBq2Ia9KWmLrNMfs5vqyB0ceXAmUrUaBspT9fy7p5gxMbV3Jk5XyO/LSQlHOqqN5diAQGAYOEEOuAicAslVaocDUqAFC4DCFEVaxOvxsQ7GJz3JrQYvHENW5D8cZtiK5UG2EwuNokjD6+FGvQkmINWtLk9U85u2crh1cu4MjKBZzfv9PV5rkrdW1fY4QQ3wATNU37xcU2KfIoKgBQOBUhRDDQB+syf6KLzXFrTBY/yrTtQcUeT5A/voKrzbk3QhBZriqR5apS+6nhXDp2kB3TPmHvnMncTL3mauvckWDgUeBRIcROrGcFJmuadtW1ZinyEq5/jFDkCYQQMUKI0cDvwBiU878rwdEx1HvhHfqvPkHTEePd3/nfgdDYUjR69SP6r/mdhkM+JCSmpKtNcmcSsV4TvwshRgshYlxtkCJvoAIAhUMRQlQXQnwLHAaew0OW+i3BoUSWr+bUOQtXb0Cbj7/nwWW/UfXhQVjyhTl1fkfgExBEpV5P0m/JPjpM+IHYeveBEE6bP3+ZKvgEhThtPp0EY71GDgshvhVCVHe1QQrvRm0BKKQjhDAA7bDezDziUJ/BaKJgpVrE1GlGTJ1mGM0+zH20jVPmjqnTjHovvENEmYpOmc8lCEFs/RbE1m9B8uF9rBs9mMMrFzh82rTzp2jx0VKyMm5wavMyTm5ezoW9W9w9pdEIdAG62A4Nvg/M0zQt27VmKbwNFQAopCGECAD6As/gAQ14QoqWIKZuM2LqNKdIzUb4BAQBcPKXtcx+uCU3rl526PzhJcvR4KVRxNRt7tB53I2wuDK0/XQuf2xZzZp3BnF2z1aHzZV24TRLnmpOk3e+J7HvKyT2fYWbqVc4s3U1J7cs5+TPy0g5fcxh80vg1qHBQ0KID4GvNE1TuZcKKahCQArdCCGigKeAAUCoi825K77BIRSt2ZiYus0pWrsp+QoX+9d7Di2by+IXepB5I91hdgTkj6L20yNI6NgXYTQ6bB6w1gHYNHaEXWNrDhz6Zx0Ah6Fp7FswnfUfDOHa6d8dNo3Rx0KDYZMpWr/tv/529Y/DnNqynJObl3Nm22oy0tz60OIlYBwwRtO0M642RuHZqABAYTdCiALAS8BjgJ+LzfkXwmikYIUa1mX9us2IKl/9ng5314wJrBwxEC0ryyH2mCz+VH3oeao+PMgpufvgAQGAjcwb6Wyb/CFbJozkZopjDsILg5Gaz31IfLuH7/qe7MwMzu/ZzMnNyzi1ZTkX9m8D97xHXgc+A0ZqmnbO1cYoPBMVAChyja0L3yBgIOAcT5YLohJrUDqpG6VadiIgf1SOxmwaO4KNY4c7zKZiDVrSdMR4AiMLOWyOO+EpAcAt0i6eY8Xrj3Fo2VyHzVHxwVep2G9Izuw5f4qjK2ZxZNm3XDy4w2E26SAVGAuMUl0JFblFBQCKHCOECAWex7rcH+Ric/5GeIkE4pO6Urp1V/IVKZ7jcVp2NitHDGTXt+MdYpfZP5AGL4+mfOe7P3U6Ek8LAG6xd+4UfnrjaYetBsS370/NZz/MVUGlKycOcnT5TI4sn8nV339ziF06uIY1lXC0pmmXXG2MwjNQAYDiPxFC5AOexXq4L5+LzfmT4OgY4lt3oXRSN7ty5bNu3mDR8z04tGyOA6yDQlXrcd87k+541sBZeGoAAHDt9AmWvtyP339e5RD9mAbtqD9sMkazb67HXjywnSPLvuXoyu9IO+9WJZCvAB8CH2iadsXVxijcGxUAKO6KECII69P+87jJ4T6/sAhKtexE6dZdia5U2+6c8hvXrjDv8fZ2N8q5F0YfX+o88z8q933W5SV7PTkAAEDT2DZlDOvff8UhBzMjE+vSZOR3+ATYF9dq2dmc3bmOI8tncnzVbG5cdZuH70vAaKyHBd36VKPCdagAQPEvhBA+WPf3XwHCXWwOPgFBlGjWntJJ3SlSqzEGo77s1ZRzp5jTvzUXDuySZOFfFChbiRbvTia8RIJ0bXvw+ADARvLhfSx5sY9DUgZD48rT7L15+OcvqEsnOzODkz//yNHlMzmx7gcy090iW+8i8BYwVtO0m642RuFeqEqAir8hhGgL/Ir16cGlzr9wtQa0/uBbHt1whvve+YqYus11O//0K8l837eZQ5x/+c4P023mRrdx/t5EWFwZus5YT4Uuj0jXvnR4N0ufaan76d1gMlOkTmvqD5tM1wXHqf/aJAqUryXJSrsJx3ot/2q7thWKP1EBgAIAIUQ5IcQyYB7gssLtJl8LCR370nPuNjpNXUmplp0w+VqkaGempzH3kTYkH9kvRe8WBqOJRq9+RNMR4zGYzFK1FX9hMJlpMvwzGg8dqzsQ/CdXjh9g+YvtyUyX06HXZAmgePOutPp0JW0mbiCuRQ+7zhpIpCQwTwixTAhRzpWGKNwHFQDkcYQQ+YUQnwI7gKausiMwshC1n/kfD686TvO3viCitNxeQdlZmSx8pgund26SqmsJDqXD54uo2HOgVF3F3Uns/hj3T/oRS4jcBarzezazamhP6WWCw+MrUW/IRDp9/xuVHhqqe6tBJ02BHUKIT4UQ+V1piML1qAAgjyKEMAshngV+w1rIx7El6e5CwcSatBo9nYdWHqHGgFfwC3XMPWn5a49ydNUiqZphcWXo9t0mitZuIlVX8d8Urt6A7t/9THhJuQ+zf2xczIaRj0vVvIUlNILEvoN5YNYB6g+bTESCy3r9GLFe878JIZ4VQqhlqzyKCgDyIEKIJKz7/O8DTm+VZjCZKd2mO91nbaLrjPXEt+4ifUn3dta/P4Q9s7+SqlmsQUu6zdhASFG3b3ngteQrXIxuM9YT17SdVN1Di6eydfxrUjVvx2AyU7xpZ1qPW03ShHXENe+GwezjsPnuQQjWe8CvtnuCIo+hAoA8hBAiXgjxI7AAKOXs+f3DC1Dzidd4eNUxWo6a6pR2u9unfszmCe9I1azS7znafTYfn0CP6Gzs1Zj9A2n78ffUGPCKVN3d095j33efSNW8E/nLVKHea1/S6buDVHzwVfzCIh0+5x0oBSwQQvwohIh3hQEK16C6AeYBbEt8LwNDAKefRCpQtjKVej9FfKvOGH2cN/2BRTNZ9dazUjXrPvcW1R55SaqmQidCUPuZ/+GbL4w1I1+QJvvzmEFYQiMp1uQBaZp3wy8skor9hlCh5yCO/vQ9+777hAv7HNcl8S40A3YKId4E3tE0LcPZBiici1oB8HKEELWA7cAInOz8IxOq0H78QnrM3kLZ9r2c6vxPbFzJ0pf6SG3k0vCVD5Tzd2Oq9HuWRq+Nsbs41L/QNNa++RCnt/4kRy8HGMw+xDXvRtKEdTQfvYD8Zao4bW4bvljvFdtt9w6FF6MCAC9FCBEkhBgLrAOcmpiev1R52o6dTffvN1OsQUtnTg3Aub3bWTCwI1kZkuqeCEHTEeOo1PspOXoKh1GxxxM0HT5OWhCQnXGTla90Ifm3nVL0ckN09aYkTVhHk7dnERpX3tnTJwDrhBBjbRVBFV6ICgC8EFvBj73AEzjx3ziseGlavf8NveZtl34wK6dc+f0Ic/q35maqnOqnwmjkvrcnUb5zfyl6CsdTvvPD3Pf2l9LKMGekXWPZC225duqoFL3cUqRuEu0m/UzD4dPIF+PULXoD1nvIXlVEyDtRAYAXIYSIEkLMwlrMp7Cz5g0pGkeLkZPpvWAX8a06y1uCzSVpF88x+6GWpF08K0XPYDLT6r2vKdu+lxQ9hfMo2743LUdNlZZdcj35HD8+l0T6pfNS9HKNEMQ2vp/2U7ZS95XPCYp2aoOpwliLCM0SQuSsv7bCI1ABgBcgrPQH9gGOP7FkI6hgUZr9bwJ9Fu+lTLueCKNLSgkAoGVl8cOzXbl84pAUPaOPL0ljZlGqZScpegrnE9+6K60++EZadcZrJ4+wamgPtOwsKXr2IAxGSrTsSYevd1LrhY8JiCjkzOkfAPYJIfoL4aIoXyEVFQB4OEKIosBKYAJOyukPLBBN46Fj6ffjAcp1esihOfw5ZePY4fyxebUULYPRRNKYWcQ1biNFT+E6SjbvSOsPvpG2HXBmx1q2f/E/KVp6MJjMxLd7mI4z9lD9qVH4hRVw1tQhWO81K233HoUHowIAD0YI0RXYCTR0xnz+4QVo8PJo+i37jcTuj2F0TfGSf3F8w3I2j39bml6T4Z9RvGFraXoK11KiWQcavTpGmt6uqe9ycvMyaXp6MJp9KdtpIPfP2EeVAW/gG+y0rt0NsaYMdnXWhAr5qADAAxFCBAshpgDf4ISnfrNfAHWefYMHlx+ict9npDXnkUHKuVMsfqEnWna2FL1aA4dR7oEHpWgp3IfE7o9R/dHBcsQ0jbX/e5C086fk6EnAZPGnfI/neWDmfhL7voLRxynXaAjwjRBiihBCVcXyQFQA4GEIIWpjbdzjlJNpJZp1oM+iPVR/dDBmvwBnTJljtKwsFj3fg+vJcg5mlev0EDUHDpWipXA/6jz7Bgkd+kjRSr98gdXDe7v0PMCdMAcEU+mh12g/dRuFazktBbcX1gZDtZ01oUIOKgDwEIQQJiHEcGAN4PAjwCFF4+gw4QfafPwdQQWLOHo6u9gwZhgnt6yRolWsYSuavv6ZFC2F+9L0jQnE1rtPitbZnevZPnG4FC3ZBEUXo+m7s2n89kwCo5yyVV8MWCOEGC6EcP2hIEWOUAGAByCEiAPWAkNxcNc+o48vNQcOpdeCXcTWb+HIqXRxfN2P0mr8R1WoTtKHM1yaxaBwDrcOeEaWqypFb9e09zj5849StBxB0bptaD91OxV6veiMhkNGrPeotbZ7lsLNUQGAmyOE6It1yb+mo+eKrXcfvRfuotbAYW61z/9PUs6eZPGgXlLK/IYULUH7cfMxWfwlWKbwBMx+AbQfv4CQohJ8lO08QOr5k/q1HITJ4k/lR4bT7qstRFdt7Iwpa2LdEujrjMkU9qMCADfFdtBvJjAJCHTkXIFRhUkaM4sOny9y+/a22VmZLHquO9cvXdCtZQkJp8PERfiFRUiwTOFJ+IcXoMPExVhCwnVrpV+5yJrXe5OdlSnBMseRr2gpmn/wAw2HT8M/ItrR0wUCk4QQM9UBQfdFBQBuiBCiLLAFcGgVGoPJTNWHXqDv4r2UbN7RkVNJY8OHr3Fy6zrdOsJgoNX70+U8BSo8kpCicbR6f7qUGgFnd21g++ev6zfKCcQ2vp8OX+8koevTzqjh0QnYYrunKdwMFQC4GUKITsDPWHt0O4xC1erTc+5W6g0a6Xan++/G0dWL2TJxlBStWk8NJ6Z2UylaCs8lpnZTaj0l5yDf7unv88fGJVK0HI3ZL5BqT7xDmy83EZlYx9HTlQJ+tt3bFG6ECgDcBCGEUQjxHjATBy75+4dH0mLkZDpP/YnwEk5tEqiLa6d/Z4mk9r7FGyVRQ1ZOuMLjqfHoYIo3StIvZGsfnHruD/1aTiK0eAItxy6n3pCJWEIduhUWCMwUQrwnhFCnbd0EFQC4AUKIAsBy4HlHzhPfugt9bXX7PQpNY/GgXqRfvqhbKqRoHC3eneKyhkUKN0QIWrw7Rcp20I0ryawZ0VdKoOpM4lr0oOP03RRr4vCH9OeB5bZ7nsLFqADAxQghagBbcWA5X9+gfLQcNZVWo6fjG+yUdgFS2TVjAid/Watbx2Txp83H3+EblE+CVQpvwjcoH20+/k5KNsjZnes5MG+iBKuci09gPhq8PoX6r03CJ8Ch10hDYKvt3qdwISoAcCFCiEexFvZxWOveQtXq03Pedkq36e6oKRxK6vnTrBstZ7m+6Yhx5I+vIEVL4X3kj69A0xHjpGhtHf8a1y+ekaLlbIo370rbrzYTmVjXkdMUxlo46FFHTqK4NyoAcAFCCIsQ4ktgHOCQ6hwGk5k6z71Jp8krCI6OccQUTmHVm89w49oV3TqJ3R+jTNseEixSeDNl2vYgsftjunVuplxhy9gXJFjkGgKjitJizFIqPzJCWjvlO+ADjBNCfCmEcN/CI16MCgCcjBCiILAO6OeoOcKKl6brjPVUf+RlaW1QXcGRVT9wcMl3unWiEmvQYPD7EixS5AUaDH6fqET9q9NHln/PuW2ekRVwJ4TBQIVeg2g9bjX5YuIdOVU/YJ3t3qhwIp7rHTwQIUQ5YBNQxVFzJHYbQI/ZW4hMcNgUTiEjLYWVwwfq1jH7BdBy1BS3aV2scH+MZh9ajpoiJT127TtP42NMl2CV6wiPr0SbiRso3f4RR05TBdhku0cqnIQKAJyEEKIJ1id/h3Tm8A8vQPtxC2g87BOvKGu7Ycwwrp0+oVun3ovvun11Q4X7EVK0BPVefFe3zrXTJ/hlwnAC85k8OvHEZPGn5vMf0fTd2Y5MFyyKdSWgiaMmUPwdFQA4AVtN7MWAQ47WFm/Yml7zd1KsYStHyDuds3u2sn3qx7p1Yuo2J7HbAAkWKfIiid0GEFO3uW6d7VM/Jvm37QSFmDEYPDgKAArXakn7yVspUtth95p8wGLVR8A5qADAwdha+E4CpJ+kMVn8afL6p7QbNx//cO9Iq9Wyslj+2gC0LH191i3BoTR/0/NSsRTuRfM3J2IJDtWlceszbRDZBIWYMBo9OwiwhEbQZOT31Hp+jKNWG81Y+wi4Z69lL0IFAA5CCOEjhJiCtT2mdAqUrUzPOb9Qoat3ZdFsmzKGc3u36dZpPGwsgZGFJFikyMsERhai8bCxunXO7d3GtiljMBgFQaFmTGbPDgIA4tv3p80XGwkvVdFRUwwVQkwRQqgDPA5CBQAOQAgRAiwBejlCv3Sb7nT5Zi2hxRx6MtfpXD11nI1jhunWKdWyE/Gtu0qwSKGA+NZdKdVSf4W8jWOGcfXUcYSAwHxmfHw9//abr2gpWn32E8WbO+x66wUssd1TFZLx/E+gmyGEiAHWA42kaxsM1HvhHVqOmorJ1/vSZlcOf4KM66m6NALyR9Fk2CeSLFIorDQZ9gkB+aN0aWRcT2Xl8CcAayXqgGATvn6eXxbf6GOh/muTqPrYm45KO24ErLfdWxUSUQGARIQQlbGm+UlvfekblI/24xZQ9eFBsqXdgoOLZ3F09WLdOs3enCilx7tCcTuWkHCaSThTcnT1Yg4unvXn7/6BRvwCPD8IACjX/TmajpztqDLCZbGmCVZ2hHheRQUAkhBC1AZWAvoeE+5AaGwpus3cSGz9FrKl3YIbVy+z6s1ndOsk3N+PYg1aSrBIofg3xRq0JOF+/fW7Vr35DDeuXv7zd4u/kYBgk25dd6BQzftoPWENwUVKOkI+Clhpu9cqJKACAAkIIRoDP+KANL/YevfRbeZGr9vvv50NHw0l9YK+uumWkHDqDxopySKF4s7UHzRS9wpT6oUzbPjo72eDfXwNBIV4dq2AW+QrWoqkCWspVEN/CuWd5IEfbfdchU5UAKATIUQr4AdAf9mwf1Cl33O0H7fAIzv45ZTLJw6za8YE3Tp1n3tLLf0rHI4lJJy6z72lW2fXjAlcPnH4b6+ZzAYC85m9IgjwCcxH03dnk9D1aUfIBwA/2O69Ch2oAEAHQogHgLmA1BN5Jl8LLUZOpv5LoxBG79gfvBsbPhpKdmaGLo2oCtUp3+khSRYpFPemfKeHiKpQXZdGdmbGv1YBAExm4fFVA28hDEaqPfEO9V79AqOP9EPLFmCu7R6ssBMVANiJEKIX8C2SC/wEFoim09SfKNOup0xZt+T8vh0cWDRDl4YwGKx52t5wx1R4BkLQeNhY3SfeDyyawfl9O/71usls8JozAQBx93Wn5dhl+OeX3uvHDHxruxcr7EAFAHZg62E9GZD6eB5VoTrdvvtZ99OFp7DugyGgabo0KnR5xOMbHyk8j8iEKlToorM5jqZZr4E7YPYxEOhFQUD+MlVJ+nw9+ctUlS1tBCbb7smKXKICgFwihHgOGAdIfeQs064nnaetIrBAtExZt+WPLas5tkZfq1S/sAhqP/uGJIsUitxR+9k38AvT1xjn2Jol/LFl9R3/Zvb1rpUA//wFafnJcuLu6y5bWgDjbPdmRS5QAUAuEEK8BoyWrVvnuTdpMXIyRh9f2dJuy7rRd37yyQ31Bo3UXaddobAXS3Ao9SRkntzrWvDxNeAf5D1BgNHsS71Xv6DyIyMcIT/ado9W5BAVAOQQIcQbgNRPrTAYaDpiHNUfeVmmrNtzeMV8Tu/YqEsjulJtEtr3lmSRQmEfCe17E11JX1r66R0bObxi/l3/7msx4B/oXYeBK/QaRO1B+s9R3IERtnu1IgeoACAHCCEGA/ofWW/DYDLTctQ0ynfuL1PW7dGys1l/l33PnCKMRnXwT+Ee3DoQqDNbZ/0HQ9Cys+/6d18/76kYeItSbR+i/tCvMJikN0odYrtnK/4DFQD8B0KIgYD+xN/bMFn8aDt2NvGtu8iU9Qj2zpvKxUN7dWmUu78fEaUTJVmkUOgjonQi5XRWCLx4aC97502953ss/t4XBBRr0onGb83A6OsnW/ot271bcQ9UAHAPhBB9gTEyNX0Cg+n4+SKKNcx7NSyybt5g45jXdWmYLP7UHKi/Y6BCIZOaA4dhsvjr0tg45nWybt6453ss/kYs/t4VBBSu1ZLmo+djDgiWLT3Gdg9X3AUVANwFIUQnYCIST/v7hebngcnLKVStvixJj2Ln9M+4dvqELo3KfZ7OM5kSCs8hsEA0lfvoq3p37fQJdk7/7D/f5xdg9IougrcTmViXFh8twZJPajVPAUy03csVd0AFAHdACNEa+BqJef6BkYXoPG1Vns1Zv5lylc3j39alYQkJp1r/FyVZpFDIpVr/F3WXo948/m1uplz9z/f5BxrxtXjX7Ts8vhItP1mOf4TUAN8IfG27pyv+gXd9giQghGgEfIfECn8hRePoMn0NYXFlZEl6HFsnvc/1Sxd0adR4bAg+gdKXCRUKKfgEBlPjMX0HXK9fusDWSe/n6L3+QSZ8vCwIyBdTmlafriSoUHGZsmbgO9u9XXEb3vXp0YkQoiYwH4m1/cNLlqPz9DUEF4qVJelxpF08x9ZJH+jSCC4US2L3xyRZpFA4hsTuj+m+1rdO+oC0i+dy9N6AIBM+vt51Gw+MiqHVpysJLZ4gU9YCzLfd4xU2vOuTowMhRCKwCAiUpRmVWIPO034iIH+ULEmPZPO4t8hIS9GlUfvpERjNPpIsUigcg9HsQ+2n9ZULyUhLYfO4nCceBQSbMPt4163cLyySFh8vI6JsNZmygcAi271egQoAABBClAJ+BKSVlStSsxEPTPoRS74wWZIeSfrli+ye9YUujYgyFSnTRnr5UIXCIZRp052IMhV1aeye9QXply/m+P0BwSaMRu+qi+EbHErzDxdRsHJDmbKhwI+2e36eJ88HAEKI/Fif/AvI0oxr0pYOE37A7C9tMcFj2fnteDLT03Rp1Hv+bVX0R+E5CGH9zOogMz2Nnd+Oz82UBHhJG+HbMfsF0vS9uRSt20ambAGsKwH5ZYp6Ink6ABBC+AJzgThZmsUatiJpzKw8Vdf/bmRl3GTntE90aRSp2YiYus0lWaRQOIeYus0pUlPfmbOd0z4hK+Nmjt9vNAqvah50C6PZl4ZvTKdwrZYyZeOAuTYfkGfJswGAEEIAXwF1ZGkWqlqPpA9nYjB630VoD/sXTCf1whldGrWfGi7JGoXCuej97KZeOMP+BdNzNcbsY8DPy/oGABiMJhr972siE6XdrsF67//K5gvyJHk2AADeALrKEitQthLtx83HZJFe0tJj0Xvyv3C1BkRXlnrBKxROI7pyHQpXa6BLw55ryOLnfTUCAIy+fjQZ+T1hJSvIzO+OuQAAIABJREFUlO2K1RfkSbzvU5IDhBD9gFdk6YXGlqLjxMUqR/02jq9fxsXfftWlUX2A6ueh8Gz0foYv/vYrx9cvy/U4/yATJrP3Pdj6BOSj+eiFBBcuIVP2FZtPyHPkuQBACNEYyPnpmv8gqGAR7p+0FL+wCFmSXsHWL0frGh+ZUIWYOs0kWaNQuIaYOs10V/+091oKDDZhMHhfEGAJjaD5Bz/Irhg43uYb8hR5KgAQQpQBvkdSlT+/0Px0/GIJQQWLypDzGi4c3G3XU8vtqKd/hbeg97N8fP0yLhzcnetxwiAI9MLMAIDAqKLc98EP+MpLszYD39t8RJ4hzwQAQogCWNP9QmTo+QQG02HiIsKKl5Yh51Vs07n3HxZXhhJN20uyRqFwLSWattddBtzea8poEgQEeeeh5HwxpWk2aj5mP2np1iFY0wOlpYS7O3kiABBC+GEt8RsrQ8/ka6HdZ3PzbGOfe5F64Qz7F36jS6Na/5dU3r/CexDC+pnWwf6F39idUWP2NeAX4H2ZAQD5y1Sh8TuzMJqlZfPFYi0ZnCdOc+eJAAD4EqghQ8hgNNH6wxm6T/d6K7nNXf4nwdExlG7TTaJFCoXrKd2mG8HRMXaP11tTw+Jv9LqeAbcoWLkhDV6fgjBIC3JqYPUZXo93fiJuQwjxFLLS/YSg+dtfUrxRkhQ5byMzPY2d34zTpVH14UGqjoLC6zAYTVR9eJAujZ3fjNNVVdM/yITR5J0ra0Xrt6X2S5/KXDnsavMdXo1XBwBCiNrAe7L0Gr36EWXa9pAl53XsmT2Z9CvJdo/3D48k4f48mY2jyAMk3N8P//BIu8enX0lmz+zJdo8XAgLzeWdmAEDJVr2p9ri+Esz/4D2bD/FavDYAEEJEArOQdOK/1pOvU7HHEzKkvBItO5ttkz/SpVG57zOYfKV1YlYo3AqTr4XKfZ/RpbFt8kdo2dl2jzcYbOWCvTMGIKHr01To9aIsOTMwy+ZLvBKvDACEEEbgW0BKomhij8ep+cRrMqS8liM/LeTy8d/sHm+y+FG+S3+JFikU7kf5Lv11VQu9fPw3jvy0UJcNJrMgINB7t9kqPzKcUknSVhKjgW9tPsXr8MoAAHgbaChDqEiNhjR8RV9aW15g66T3dY0vndQNS7C0bswKhVtiCQ6ldJK+Q656rzUAH4vBK8sF36Lm8x8RWUHa6n1DrD7F6/C6T4AQogOg77SNjeDoGFp/OEMdSvsPzu3dzslf1urSUNsriryC3s/6yV/Wcm7vdt12+AWaMBi9cy/AYDLT8H/fEBBRSJbkIJtv8Sq8KgAQQpTC2uFPNyaLP20/mY1faJ5vGf2f7J1j/8EkgEJV6hJRpqIkaxQK9yaiTEUKVamrS0PvNQfWQ4HeWiQIwC+sAI3emonRR9q5oq9sPsZr8JoAQAjhj7XMr5SOPM3f/Fw5pRyQnZmhu/BPonr6V+Qx9H7m9y/8huzMDN12mMwCi79Xbm8DkL90ZWq/aH/9hH8QjLVcsL8sQVfjNQEA8DlQToZQ1YdeIL61tE7BXs2Rn37g+qULdo8PiChIyeZet7KmUNyTks07EBBR0O7x1y9d4MhPP0ixxS/AiMlL6wMAxN3XnYTOT8qSK4fV13gFXhEACCH6A91laMXUaUbd573yvIdD2DvnK13jK3R5BINJSqamQuExGExmKnR5RJeG3mvvdvyDvbNp0C2qPvE20VWlNfvrbvM5Ho/HBwBCiJKAlGP6IUXjaPXBNwiDx/9vcQppF89xdPViu8cbTGaV+qfIs5Tv0l9X8Ht09WLSLp6TYovRKPAL8N7zAMJgpMHwaQRFF5Ml+YHN93g0Hu3phBAmYBoQoFfL7B9I20/nqFS0XLB/wXSyszLtHl/yvo66lkEVCk8mIKIgJe/raPf47KxM9i+YLs0eXz8DZh+Pdgn3xDc4lMZvz8Rk0e0uwOpzptl8kMfi6f/aQ4HqulWEoMXIrwgvkaDfojzEHp0nkVXqnyKvo/ca0HsN/hP/ICPC073CPQgtXo66Q6Rt4VfH6oM8Fo/9p7bVaH5FhlaNx4ZQopk6iJYbzu3dzoUDu+weH1GmItGV60i0SKHwPKIr19GVbXThwC4pNQFuYTB4d5VAgNiGHajQW1975tt4xZP7BXhkACCECMK69K87f6V4oyRqP/m6bpvyGnvnTtE1vnynhyVZolB4NnqvBb3X4j8x+3p3lUCASg8NpUjtVjKkjFi3AoJkiDkbT/1XHgPoPs0RVrw0LUdNldlCMk+QnZmha+/R6ONLfJJKs1QoAOKTumL08bV7/P4F06XUBLgdb64SCCAMBuoPnUS+olLq+hTD6pM8Do8LAIQQDwB99er4BATR9pPZ+ARKqRuUpzi6apGu3P+4xm3UYUuFwoYlOJS4xm3sHn/90gWOrlok0SLvrxIIYA4IpvHbszD7S3l472vzTR6FRwUAQohoYLwMrYZDPiS0WLwMqTzHHp35x2U79JVih0LhLei9JvRek3fC26sEAuQrWorqT78nS268zUd5DB4TAAghBDAZCNOrVaJZexI69tVtU17kevJ5Xbn/AfmjiK3bXKJFCoXnE1u3OQH5o+wef3T1Yq4nn5dokRW/ACNGL64SCFCyVW+K1m8rQyoMmGzzVR6BxwQAwECgqV6RgPxRNB0hZREhT7JP535j6bY9EEbvfqpQKHKLMBop3baH3eOzMzPYJ7EmwO0EeHmVQIDaL36KX1ikDKmmWH2VR+ARAYAQogjwlgyt5m99oTr86UBvF7KEjn0kWaJQeBd6rw0ZHQLvhLVKoHcH7ZZ84dQdLO3B8C2bz3J7PCIAAD4BAvWKJHZ/jNj6LSSYkzc5v28H5/fvtHt8ZLmqqtiSQnEXwkskEFmuqt3jz+/fyfl9OyRa9Be+ft6/FVCo5n2U7vCoDKlArD7L7XH7AMB2stL+I7I2QovFU//FdyVYlHfRW3WsbIfekixRKLwTvdeI7MqAt+Pv5QWCAKo+/pas1MA2npAV4NYBgBAiHxLyKw1GEy3fnYzJ4jVtnJ2Olp3NgR9m2D3eaPahdFI3iRYpFN5H6aRuGM0+do8/8MMMtOxsiRb9hcks8PHyAkEmiz/1Xv0Sg1FKsDPG5sPcFnf/1xwJ6O4WU/OJ14gsX02COXmX0zs2knbxrN3jizdKwpJPdwKHQuHVWPKFUbxRkt3j0y6e5fSOjRIt+jt+AUavPxCYv0wVEvtKqTJfEKsPc1vcNgAQQtQB9DXMBgom1qT6o4MlWJS3Obxivq7xZTuow38KRU7Qe63ovVbvhcHg/bUBACr0fpGIBP195oBHbL7MLRGaprnahn8hhPABtgNl9eiY/QLoOW87IUXj5BiWh/mqRRkuHTto11jf4BAeXX9a19JmXiLzRjqZ11PJuJ5KRprt+/VUMq9f//Pn21/PSEu9w/vTyEhL5dqZ3+3OD/cLiyAoqghm/wDMfv6YLP62n22/+9l+9g/AbLH9bvvZ7Gd9r8n2XrNfACaLP8Lgts8cbkNWxk3G1ynIjauX7RofGluKvkv2Sbbq71xNziAry/18h0yunTzCvL7VyUxP1Su1F6ikadpNCWZJxV1PdbyETucP0GDw+8r5SyD58D67nT9YS//mNeevZWWRevEsqedPk3ru9J/fU86dIi35HBlpKWSkpdkc+98duqP2cHPL9eTz0ovLmHwtfwUOtsDAEhJGQEQU/vmjCMgfddvPkfhHROW5stFGsw9xjduwd+5Uu8ZfOnaQ5MP7CIsrI9myv/ALNJJyJdNh+u5AUKHiVH/qXTa8q7tteVmsPu1/+q2Si9sFAEKIUsAQvTrFGyVRvrPqOCcDvUuKJVt0kmSJ68nOzCD1/Jm/HPr5W879lPX7+TOknjtNWvI5t3Hk7kTmjXQyb6STfvlijscYzT7WgCDCFhT8LUiIIiAi8s+fTRY/B1rvPEq26GR3AADWa9aRAYDZx4DZx0DGTe/+jJdq8yC/r1/E7+t/0Cs1RAgxQ9M0+5+kHIDbbQEIIVYBDfRo+IcXoNf8nfiHF5BjVB7n2y51OL1zk11jfYPy8eiGM26/ApCdlUnKmT9IPX+alNue2FPPnbI5eavTv37pArjZNaP4C5/AYALyR+FvCxZu/ZyvUCwhsSUJjSnpEQ3AsjJuMr52FDeuXbFrfMHEmnSdsV6yVX8nO0vjSrLcLoTuSPql88ztU4X0S7pXw1ZrmtZQgknScKsVACFEN3Q6f4Cmw8cp5y+J1AtnOL3rZ7vHF2+U5LbOX8vO5tjapfy29DsOr5hP+pVkV5uk0MnNlKvcTLl6zy0r//BIQouVIjS2JCExJQmNLUVosZLkKxKHydfiRGvvjtHsQ/FGSeyb/7Vd40/v+pnUC2d09Rf4LwxG64HA9LQsh83hDlhCI6g96BNWvtJZr1QDIUQ3TdO+kWGXDNwmABBCWIB39OoUa9CSuKbtJFikADiycoGuJ153Xf7PvJHOkkG9+O3H2a42ReFk0i6eJe3iWU7+svZvrwuDgaCoItbAoFgpa2AQU5KQ2JLkKxTr9B4WJVt0sjsAQNM4snIB5Tv3l2vUP7D4G7mZnk12tnevihWt14bCtVrwx8YleqXeEULM0TQtXYZdenGbLQAhxCvAm3o0jD6+9F64Wx38k8jcR5Ps7v7nExDEgI1nMfr4SrZKHzdTrjLnkSRObXPsEqnCezCYzIQUjSMkpoRtxcAaIITElCAwspBD5sy6eYNxtSK5mXrNrvHFGrSk/fiFkq36NzdvZJN61bsPBII1K2Bur8pkZdzQKzVE0zQpvW304hYrAEKIKEB3sn7Vh15Qzl8iGWkpnNi40u7xxRsluZ3zB/hl4ijl/BW5Ijszg+Qj+0k+sv9ffzP7BRAWV4bIclWILFeVqPLWnhd6VwyMPr4Ub5TE/oX2rRif2LiSjLQUzP6626jcEx9fAzfMgswM93iYdBRBhYpTrvuz7Jyse6F6sBDiS03TzsiwSw9uEQBgTY/Q9SkNjo5RBX8kc2ztUrJu2h/tlnLD5f/0K8lsnzbW1WYovIiM66mc/fUXzv76C2DtKGey+FGgTCUiy1f9MygIjS1FbsvolWrRye4AIOvmDY6tXUrJ++63a3xu8A80cfWS9x8IrNDrRQ4vnU7KmRN6ZAKx+jzH7s/kAJcHAEKIROBBvToNBr/vNSlA7sKh5XPtHmv2DySm3n33fM/15PNcO/MHWnYWWnY2YXFl8AkIsnvOnLB/4TfcTLnq0DkUisz065zavoFT2zf8+ZpPYDCRCZWJLF+NqPLViCxXheBCsffUial3H2b/QDLSUuyy49DyuU4JAIwmga+fgRvXvTst0OjrR/UnR7FySBe9Ug8KIcZqmmZ/e1UJuDwAAEajsyRxTN3mlGjWXpI5CrCmxR2zc+8foHij1n87Ua1lZXHh4G5Obd/I6R0bOb1jE5dPHP7bGLN/IPGtu1Cx++NElKlo99z3IvXcaYfoKhT/xc2Uq/z+8yp+/3nVn6/5hea3bh3cFhQERPzV/sTka6F4o9Z2N+I6tnox2VmZsprb3BM/fxM30296fZZs0fptKVS9GSc3L9MjY8Dq+5rKsco+XHoIUAjRBtBVZcZo9qH3wl2ExJSUZJUC4PdNP/FdX/s/m01HjCOgQDSnbQ7/zK4tZFzPWUlNg8lM6w++oUSzDnbPfzdWDHuMXTMmSNdVKGQRGFnotq2Dalw9eZzlQ+3vU//AV8spUrORRAvvzo3rWaSleHdaIMDVPw4xt3cVsjN0V/dtq2naAhk22YPLVgCEEGbgPb06Vfo9p5y/A9Cz/A+wfOgAu8dmZ2bwwzNdaTFqKvGtdOfe/g2DySxVT6GQTcrZk6ScPcnh5fOk6B1aPtdpAYCvn5Eb17O9vk9AcOESlOv6NLumjtIr9Z4QYommaS45QOHKzhyPAaX0CAQVLEKNx3VXDVbcgSMrXRaUAtYtiJWvP05meppU3bimaqtIkbdw9rWcF7oFAlTo/TIBBQrrlSmF1Re6BJcEAEKIUGCYXp0GL4/GZPGXYJHids7v28HVU8ddbQbpVy+xd940qZpFqjfALzS/VE2Fwp25euo45/ftcNp8PhYDBmPush08EZPFn2pPvitDapjNJzodV20BPA+E6RGIqd3UKadb8yKHVshZepTBrzMnUqHLI9L0hNFI7adHsOL1x6VpysZgNFlb6Vr8/2y3a23Fa/vdLwCT351//rM1r62F7945U9g983O77CjfuT9l2/f6s7XwvdsP3/572r86HGamX5f8f0mRGw6tmOewg7V3wuJvJO2a9xcHim3YgehqTTi1ZYUemTCsPvFVOVblHKcHAEKIMOBJPRoGk5lGr42RZJHiFulXL3H0px/YO3uyq035k7Tkc9I1K3R9lKunjrNlwkjp2rdjsvgTWKAgAREFCbj1/dZX/sjbHPvfHbnM3gnH19t/UjmgQEGiK9eRYoeWnX2XAMLaEvnGtSvWRkxnT1obMJ37q8Nilv6DVnmevbMnE1IkjmKNWjulvbKvxUB6qvD6EsEANZ55n3l9qpKdqWsb/0khxPuapjm1IYkrVgCeA3S146rS71lCi8VLMidvk3LmDw6vmM+h5XP4Y/MasrPcK2rXshxzorjus29iyRfGLxNHWTv85QKfgCACCkRb29NGFLQ6+QLRtzn4KAILRHtE1zlnIQwGfAKCcl/nQdO4fvmiLTA4Tcq5U7YA4dTfXku7eFa1X74HV08dZ8lLfTAYTRSuXp8STTsQ16QtgVG697DvisXfkCcyAvIVLUVCl6fY/fVoPTLBWH2jU1cBnJoGaHv6P4qOACAwshB9l+zD7Bcgz7A8RvKR/RxaPpdDy+Zaq5e5ceJuviLFeXDZbw7Tz0hLYde34zm7Zxvply+SfvUyvoFBtqf2v5y61clbf/akz97GscPZNHaEXWNrDhxKrYG6j+o4BS0ri9SLZ63BwdlTfwsUbn8t/fJFV5vqPghBZLmqlGjWnhJN2xNWvLRUeU2Dq8kZeWIVIDM9ldndK5B2/pQematAMWeuAjh7BUD303/NJ17zqBuwW6BpnNm95U+nf+noAVdblGPiW8pNA/wnZv9Aqjz4vEPnUDgeYTQSWCCawALRRJa7+/syb6Rz+dhBLh7eT/KRfSQf3kfy4f1cOnZQV9lrj0TTOLt7C2d3b2H9+0MILRb/ZzAQVb5arssW/xMhwNfPwPVU718FMFkCqNj3FTaMGqhHxumrAE5bAZDx9B9cKJZ+S/erXO4ckJ2VyR8/r+bQ8jkcXjGflLMnXW1SrhEGAw8u++0/y6Uq7k5eWQHQi5aVxZU/jlgDg8O2wMDW/Ccvlo4OjCxEXJO2lGjagcI1GthdSVDT4MpF768OCNb6JbO7lSfljK4MKqeuAjhzBUD303+Nx4Yo538PMtPTOLZ2KYeWzeHoqkWkX73kapN0UbnP08r5K5yCMBoJiSlJSExJ4hq3+dvfUs6eJPm2FYOLh/aRfGQfaRflH1B1F1LOnmTn9M/YOf0zLMGhFGvYihLNOhBb775cpV4LYc0IyAurAAaTmcQ+L7N+pK60fqeuAjhlBUDG03++IsXpu2SfU2paexLZWZkcW7OEPbO/4tjaJV6TblWhyyM0Gf6Zq83weNQKgONIv5L85xZC8pF9XLT9fPXUcbc+V6MHk8WP2HotSOjYl9j6LXJ0P85TqwBZmczpXoFrp47qkXHaKoCzvKn+p//HX1XO/zYuHtrDntmT2TdvGmkXz7raHGmEFC1BxV4DqdRT116aQuFwLPnCiK5c51+pkpnpaZzfv5NT2zdxevsGTu/YRMo5XYfD3IbM9OscWjaHQ8vm4B8eSZl2PUno2IfwEgl3HWM9C2AkPS0PrAIYTST2Hcy6t3TVLnHaKoDDVwBkPP2HxJSk76I9CGPeKDF5N9KvXuLADzPYM/srzu7e4mpz5CAEYcVLU6hKHUo060hs3ea6Dx8p/kKtALgHV08d5/T2jdZumNs3cn7/TrdLudVDZPlqJHTsS3zrLnesM6Blw5XkvLEKoGVnMadHRa7+cUiPjFNWAZzxSP0sek/+P/5qnnX+WnY2JzYsZ8/sSRxaPs/jTyobTGYKJFSmUOU6FKpaj+jKtVVpXoXXExwdQ3B0DPGtuwLWVYIzu7f8GRCc3rEp1/Uo3Ilb2QSr336OEk3bkdCxH0VrN0UYrNXmhQF8LUbSr3v/KoAwGEnsO5i1bzykRyYYq+98TY5Vd8ahKwBCiADgDyDEXo3QYvH0Wbg7zwUAl44dZO/syeydN9UjT/DfwuwfSMGKNShUpR6FqtSlYMUaqn+DE1ErAJ7DpWMHOb1jE6e2beDU9o0kH97r0cWNAiMLUbZdL8p27ENobCmyszWuJGdAHlkFmNurMldOHNQjcxkorGlazvqo24GjVwD6ocP5A9QaODTPOP+bqdc4uGgme+ZM5tS29a42xy78wwsQXbkOharUpVDVukSUqajObigUOSA0thShsaUo2743ADdTrnJ658+2rYMNnNm1mRvXrrjYypyTcvYkmye8w+YJ7xBduQ4JHfpQpEFHsoX313ERBiOJ/YawZngfPTIhWH3oWDlW/RuH3ZmFEAbgGT0a4SXKUsrBhWDcgd9/XsWe2ZP4bels6e1vnUF05TokdOxLoap1CY3V1eFZoVDY8AkMJqZOM2LqNAOs24HJh/dyavtG9s6d6lEPCae2refUtvWYLM8Q06A9JVv1JqpyA1eb5VCKNX6AXZPf4fKxfXpknhFCfKppmkOWghz5aNYWiNMjUPOJoX/uIXkb2ZkZ7F/4LVsnvc+FA7tcbY4uqvV/keKNklxthkLh1QiDgfCS5QgvWY6AiILMe6ydq03KNZnpaRxeOp3DS6cTGleecl2fpljTzl5Z30UYDFTsN4RVw3rqkYnD6kvnyrHq7zjSuz6rZ3B4yXKUavGALFvchhtXL7Pl83f5onFxlr7c1+OdP0B0pVquNkGhyFN4wzV36fBu1r75MN91imf316O5meI52xs5JbZRR0KL3z1FMofo8qX3wiEBgBCiClBfj0atJ4d5VTrY1ZPHWPXWs3zeMIZ1owd7TV5waLF4LCHhrjZDochTWELCvaYjatqF02wd9yqzOpZg85hBekvpuhdCUPFB3en89W0+VTqOWgHQFbFElE6kZLMOsmxxKWd3b2HRc934snkptk8ZQ0ZaiqtNkoo3PIkoFJ6It117GddT2DtrLN93SWD16724sG+rq02SQkz9doSVqKBXxiGrANIDACFEIUDXyb2aTwz17Kd/TePwygXM7NWI6Z1qcmDRTIf1tddDcKFYEjroOqVKdKXakqxRKBS5Qe+1l9Chj1v22tCyszi64jsWPlKXxQOb8fu6hZ5dWlkIKvYbolels823SsURKwADAbtPdOQrUpy4Jm0lmuM8Mm+ks3vm53zVKoH5j7fn5JY1rjbpX1hCwknsNoAu09fw0PJDFGvYWpdeQS97ClEoPAW9116xhq15aPkhukxfQ2K3AW65lXd25zpWDO7EnJ4VOTj/C7JuprvaJLsoUjeJoOhieiTMWH2rVKQGALbCP4/q0Ujs/pjHnfy/nnyeTWNHMLFRLMuHDuDS0QOuNulvmCx+xLfqTLvP5vHoupM0HvaJtX65EJzZtdluXUtwKOFxZSRaqlAockp4XJk7lt3NKWd2bQYhiK5ch8bDPuHRdSdp99k84lt1xmTxk2ipfq6cOMiGUQOZdX9Jdkx6k/TLnlU1URgMlO6gyzUCPGrzsdKQnQbYB7D7E2my+JFwfz+J5jiW9CvJbJkwkh1ff+J2XfiE0UjRGo0o3bYnJZq1xycg6I7vO7PL/p4CURVrePZWjULhyQhBVMUaHFuzxK7h/7z2DSYzxRslUbxREjdTr3Fo2Vz2z5/GiZ9/cpstzPTLF9jx5Rvs/no0ZToOoHzPQfjqCIKcScnWfdg2cThZN+z2FaFYfeynsmySHQA8qWdw6TbddUW0ziIzPY1tkz/il4mj3K4yV2S5qpRu05341l0IyB91z/dq2dmc3WP/QRu1/69QuJboSrXtDgDO7tmKlp19xxVXn4AgyrbvRdn2vUi9cIYDP8xg/4LpnP31F70mSyHrxnV+/eYDDs7/knI9nqNsp4FuX2LcJyiEuGZdObhwkh6ZJ3HHAEAIURsorUejYo8nJFnjGLIzM9g9cyI/f/oGqRfOuNqcPwkpGkd8UjfKtOmeq9Sg5MN7dWUlqABAoXAteq7BjLQUkg/vJbxkuXu+LyB/FJX7PE3lPk9z6egB9i2YzoGF33D5xGG755bFzdQrbJswjH3ffUpi38GUavOgWxcVKn3/AL0BQGkhRG1N0zbIsEfmZvuDegYXqlqPiNKJsmyRi6Zx4IdvmdwqgZUjBrqF8/cLiyCxx+N0nbGefj8epPZTw3OdF6xn+V8YjUQlVrd7vEKh0E9UYnVdvVJyew8ILRZP7aeG0+/Hg3SdsZ7EHo/jFxZh9/yyuJ58lk3vP8OcnhU5snym22YNhJWoQGRiHb0yunzt7UgJAGwHE3Sl/rnr0/+xNUuY1rEqi57v4fKI12Txp3RSN9qPX8gja/+g8WsfUzCxpt16eg4ARsQnYvbz/qYeCoU7Y/YLICLe/gcnPfeAgok1afzaxzyy9g/aj19I6aRuLl+Gv3byCGuG92H+QzU5uWmpS225G2U6PqZXorOsw4CytgA6AXc+ZZYDAgtEU6K5exX+Ob1jI2tHv+L6VD4hiKnTjDK2w3wyne6Z3favAHhbERKFwlOJrlSLc3u32TVWzz3gFgajiWINWlKsQUsyrqdyaNlc9s2fxvH1y1z2JJ782y6WDWpPZGJdqg54g4hyNVxix50o2qAd/vkLknbhtL0SQVh97ld6bZG1BaBrSaJ8l0fcpmXsxUN7mP94e77tWtelzt83KB+V+zxNv6X76ThxMWXa9pDq/DPTr3PhwG67x0dXVvv/CoU7oOfKTuFtAAAgAElEQVRavHBgt9QMJrNfAGXa9qDjxMX0W7qfyn2exjconzT93HJ25zp+eKwhKwZ34vLRvS6z43YMRhPx7R7WKyNlG0B3ACCEKAnUs3e80exD+S799Zqhm6unjrP05b5MbVuRwysXuMyO8BJlaTzsE/qvPkGDwe8TUrSEQ+Y5t2872VmZdo9XBYAUCvdAz7WYnZXJuX3bJVrzFyFFS9Bg8Pv0X32CxsM+IbxEWYfMkxN+X7eQeX2rsfbNh0k5c8JldtyiVNuHMJh99EjUs/leXchYAdCVuF/yvvv/M13NkWRnZrB5/NtMblmWvXOnomU7pO3yPREGA3FN2nL/pGX0XribxG4DMPsHOnROPQcAAwtEExwdI9EahUJhL8HRMQQWiLZ7vJ57QU4w+weS2G0AvRfu5v5Jy4hr0tYlxd607GwOL/maOT0S2TX1XbIzM5xuwy38wiKJbah721t30Rxd/wpCCCPWwgR2U7Gn6w7/ndq+gWntq7D+g1fJvOH8EpOWfGFUfegFHlz2G20/mUPRWo2dNreuwz/q6V+hcCv0XJN67gW5pWitxrT9ZA4PLvuNqg+9gCVfmNPmvkXWzXS2TRjG/Adrcu7XTU6f/xYSDgP2sflgu9Ebht0H2B16FihbmYIVne9Mbly7worXH2dG9/pcPLTH6fOHFI2j6Yhx9F99gnqDRrqkIcdZXQcA1f6/QuFO6Lkm9dwL7CW4UCz1Bo2k/+oTNB0xjpCicU634fLRvSx6vDEbRz/FzVTnF3SLKFeD8FIV9UhEY/XBdqM3ANB1EMEVT/8Hl3zH5FYJ7Pp2vNNPqIaXSKDle9Pou3gf5Tv3d1m97fTLF3WlNKoMAIXCvdBzTV4+cZj0yxclWpNzTBY/ynfuT9/F+2j53jTC4px8TkDTODD3c+b0qMixn2Y7d26g9P26VwF0+WC7AwAhRH6gjb3jLSHhxLfuau/wXHPt9AnmDWjLD890IfW83ekXdhGZUIU2H39P7wU7KZ3UTVfhDhmc2W1/OU+Tr4UCCZUlWqNQKPRSIKEyJl+L3eP13BNkIIxGSid1o9f8nTR+cwbh8ZWcOv/1i2dYNbQHK166n9Szvztt3uJNO+Orbxukjc0X24XQ7HwKFkI8Coyzd+JKvZ6k4ZAP7R2eY7SsLLZP/ZgNHw0l43qqw+e7nUJV6lJ9wCvE1tO1SiON65cucGLDCnbNGM8fm1e72hyFQuEmFK7egApdHqVo7Sb4hdrtT6SQciWTjJvZnPz5R3ZNGcnZXVKq3uYYkyWASv2HUfaBxxEGxz+s/fzRC+z77hM9EgM0TRtvz0A9AcByoIldg4Eu36x1+F7yub3bWP7aAF0Nb+whpnZTqj/2CoWrNXDqvHci5cwf7PxmHMfWLrWm+7hpiUyFQuEGCEGBMpWIrXcfid0GEBhV2Okm3LyRTerVv1KUz+xYy64pIzm1ZYVT7QiPr0TtFz/Vu0//n5z7dROLHmukR2KFpmlN7RloVwAghIgATgN2hUdBBYvw8MqjDmslm3E9lY1jhrFtyhintrGMqd2U2s/8j6gKrq+Rf+noAbZMHMW+edNcmu6iUCg8E4PJTJl2Pan28KBc9xnRg6bB5Qs3//X6hX2/sO3z150aCAiDkbKdnqDSw0MxWRxU+lzTmPVAKVLP/WGvQhZQUNO087kdaG8A8Ahg15IDQJV+z1H/pVH2Dr8nv2/6iaWDH+TaaecVeyhQthJ1X3iHmNp2BWFSSb+SzKo3n2H/wm9cUtNAoVB4F8JgoHRSNxoO+dBpaXvXLmeQmXFn33Rqywp++WwIyb/tdIotAAGRRaj7ygQKVm7oEP0tn7zMnm8/0iPxqKZpE3I7yN4AYBlgt7frPmsTkeWr2Tv8jmjZ2Wz69H/8/OkbTnN8wYViqfPM/yid1M1hqxm54fiG5fw4+EFSzp50tSkKhcLLCIwsRPO3v3TKg056WhbXU++xeqtpHFk2g22fv07KmeMOtwesgVBin8Ek9n1FeiGjC/u2svCRunoklmua1iy3g3IdANhOHJ7GzkZC+YoU58Flv9kz9K6kXjjD4ud78PvPq6Tq3g1LSDg1BrxCYvfHMPr4OmXOe5GdlcmakYPYPvVjtcevUCgchxBU6vUk9V8a5dD+LVlZGleT/3vrMivjBvvnTGDXlHe4cSXZYfbcTlTlBjQYNhm/sEiput93Kcu1U0ftHZ6JdRvgQm4G2RPGtEdHF8H4lrq6Bv+LExtXMq1dZac4f5PFj2qPvMSDy36jct9n3MP5Z2aw6NlubJ8yRjl/hULhWDSN7VPGsOjZbg49W2Q0CgzG/15VNZp9Sej8JPfP2Ev5ni9g9HV8bZUz21Yzv191Tm/9SapusSYP6Bluwuqbc4U9KwBLgea5negWPeduI6K0/f2rb6FlZVmX/D970/FL/kKQ0KEPtZ8a7pJTsXcjOzODhc904fDyea42RaFQ5DHimrYj6cMZGExmh+inpWRx43ruDnGnnj/Jjokj+G3xVIc/EAmDgQq9X6Ziv1ekpAsmH9rF/H662hb/qGlarnLOcxUACCHCgTPYuQIQWiyevov1t2RMPX+aRc/3cEoue4GylWkybCxRie7TTxqsAdCCpx7g8Ir5rjZFoVDkUeKatKXNmO8cUtws42Y2KVfs61h6fu8WNo1+iosHd0i26t9EVapv3RII19/Ubk6PRK6cOGjv8EwgStO0HJd1zO0WgL7l/1b6l/9PbFjBtPaVHe78fYNDaPzax3T/7me3c/4Amye8o5y/QqFwKYdXzGfzhHccom32Mdh9tjqibDWSPl9PzWc/wCcwn1zD/sGZ7WuY1686p35ZqVsrtrFztwFyuwKwBB3NB/r88CthcWXsGqtlZbFx7HA2j3/b4Uv+Zdv3ot6gd/EPL+DQeezl9M5NzOzegOws+6JjhUKhkIXBaKLz9NUUTKwpXTvlaiYZN/Td79MvnWfLp4M5vORrSVbdGWEwUKHXi1R88FW7twSuHN/PnJ66yiAv1TStRU7fnOMAQAgRCpzDzhWA/KXK02u+fcsxqedPs+i5HvyxxbFP/eEly9Fk2FgKVa3n0Hn0cDP1GtPaV+bK70dcbYpCoVAA1uyunnO34RMQJFX3Rno2af9n767Do7jaPgD/drNxdwGSQAIhgSQEJ3hxdyluRVqgLXXaIi1vKaVQgeLuUjxIsEIJBAiSQBSSECHubrs77x8BikRnzuysnPu63utrYec5T/nCnmeOFpB50UkLuYnbaz9GTiy/N8DateqK7sv2sJ4SODW1HXJiQ9k2LwVgwzBMTl0+XJ8pgN7gMPzfjOXw//Og65VD/jx2/jqGxuj21a+YdPK+Unf+AHB300+086coSqnkJcbi7qafiMfV1iF3voqtd2cM2XEb7eavgrYB2ULldanBN3BqenukBt9g9TyB3QB1PqihPgUA65X/ALv5/6f+x3B85gAUZ6VzabpGjbsPwNRzYWgz/VNe97WSUFaQh5CDrO9foiiK4k3IwU0oK8gjGlMsFkEiIVcEiLUkaDFuIUbsC0bDTnUeKa+30pwMXFo0BHHXTtT7WY7rAIB69NUKKQBsPFrDzNG1Xs8E71uPs5+Oh6y8jG2zNdLWN0Sv5RsxfLMfjGwb8NIGaSEHNqC8MF/oNCiKot5RXpiPkAMbiMfV1iV76h4AGFg7oPcvJ9Dp83W8nfEvqyjD9aWTEHGsfn8mJg1duF5AVOe+uk5rAEQikRuASLbZdP38Z7Sd9UWdPx+wdjGCtqxi21yt7Ft1Qv9fdtW7KBGStLQE23s1ITIaoi0RY0g3F7RrYYe27nZo424LcxP2d4lTFKVacvJLcT8iDfciUhEUlooz/8agQsp9cbWBpQ1mXomFRI/cgTwyKYP8HP4OHcp/HoMb/5uJjNA7vLXhOelztJnzY50/H3pgLe5t/JZLk80Zhomq7UN1LQAWAPiTbSZT/B7B0rVFrZ+Ty6S49O0HCD+5h21TNRJLtNFpwVK0m/UlL/tW+RRz+RROzx/JOY53M2vsWjYArdyUc4cDRVGKFxyVjmnLziPkSb0vlHvH0PXH4dJ7GIGs/pOXVQG5nL+DfRi5DI/3r0HwjhW8nXDoOmASfL/aWKep5txn4Tg5pQ2X5hYyDLOutg/VdWyF9fC/obV9nTr/ipIinJo7lLfO39K1Bd4/Eoj2c75Ruc4fAOIC/DnH+G5WRwTtnUw7f4qi3tDKzQZBeyfju1nct/KR+K56G8nFgFURibXgNflLDN5yA2aNPXhpI/r8Plz5ahSkpUW1ftassQfXg4Xq1GfXWgCIRCJtAD3YZuHY6b1aP1OSnYGjU3oh7gb5HxyIRGgz/VNMPB4EGw9O+ysFFR9wkdPzH4zwwo/zukBbQn4+jaIo1actEePHeV3wwQgvTnG4fldVhY91AFWxaOqNIdtvocW4hbzc8Jp05yIuLOyH0tza7+xxaNOTS1M9XvTdNarLn6ovACO2WTjWcnVkXmIsDo3vgrTHQWybqJa+uRVGbfdHt69+VYqLe9jKjX+KvOesb4mCs4Mp1izqQS4hiqLU1ppFPeDswP70vLznz5AbT/bGV4k2+1MB60tLWxft5q9C37V+0DO1JB4/M+I+zs3rUevNf/Zta395roERKvvuGtWlAOC0/c+xY/X/EenhD3BofBfkJkRzaaJKdl7tMfH4PTj69iIeW9HSQu9zen7nsv4wNtAhlA1FUerM2EAHO5dx2yLH9TvrbSJRZRGgSA5t38OQHbdh5d6WeOz85zE4N69HjXcV2LflNAIA1KHv5rUAMG/sVu3tefG3LuPo5PdQnJXGNny1vMbNxtj912Fs34h4bCEUZaSyftbB2gg92qjHnwNFUYrRo00jOFizHvjl9J1VHQnP6wCqYmjTEAP/ugK3YbOIxy7JTseFBX2RHHSl6ratG8DUsRmXJrgVAC9u/2vNtvXq3r4Tbl3BqTlDUF5UwDZ0lSR6+uj38070Wr4RWtrq88bLpUhq3dyWYCYURWkKLt8dfLzYSQRavyTW1kGnz9ehy+Kt0NIlt70RACqKC3D5q5HVXiTEcRqg9Ys+vFq1/Yn2qsNnquXU6d35/7TQezg9fyRkFeVsw1bJtFETjD8YAI/hU4jGVQZcqunWzemKf4qi6o/LdwcfIwBaBE8EZMN1wCQM2ngNxg6NicaVV5Tjn8XjkBn54J3fc+BWAIhR2YfX+IGadGbbskhLCw3bd3/j13KeReHEB4NQUVzINmyVGvcYiAnH7sLandPpSUqrJIf93twWLlYEM6EoSlNw+e7g8p1VHZFI+CLAoqkXhmy7hYadBhCNW1FSiMufD0VewpM3ft3OpxvrmwVfqLEPr60AqHUVYXVsW7aFronZq38vTEvCsRn9UZJT+/aH+mj3wZcYvvE09EzMicZVJnKZjPWzOtqqd+YBRVHC4/LdweU7qyYk7wVgS8fYDL1XHYPnxM+Ixi3Ny8LFRYNRnJH8X1tGprBqznoWHqilD6+2ABCJRPoAvNm2+vrq/9K8bByfOQAFKQlsw71DJBaj53d/oMtnK3nZr0lRFEUpFy0F7wSolkiENnNXoMMnayASk8upKC0RFz8bgrL8/27zted2HoD3i768SjVl3hZArQcJVOfl/n9paTFOzhmKrGhydzBr6ehi0G+H0GrSfGIxKYqiKOWmDCMAr3Mf9SG6L98HLW1y58zkPgvH5a9GQFpaDIDzOgBtVPblVaqpAOjEtkWJnj4cfDpBLq3AmYVjkBIcyDbUO3SNTTFy+3k07TeKWEyKoihK+WlJREo34OvcYwT6rD0DHUP2hye9LSP0Dv75fgLk0gpYe3bkuvug2r6clwKgQZsu0NLWgf83MxD37wW2Yd5hZNsAY/dfR8N23Wv/MEVRFKV2hF4IWBW7Vl0xYMNlGFg7EIuZdNsfAStnQ0uiA1tv1uvxAUUXAI6+vXFt5SJEnjnANsQ7LFzcMf5QAKyaeRKLSVEURakWLSW9z8S8SUsM2ngNpk7NicWMvXgId9d9yXUaoH4FgEgkagyA9SkQqSF38HAP69uD32Hr2Q7jDvwLY3tHYjEpiqIo1SPRVr4RgJcMbRth4IarsHLndJXvG8KPrkdG2F0uIWxf9OnvqO5iYtZv/wDw9OJxLo+/wdq9FUZuP6/W2/woilJNJWVS5BWWvfa/cuQWlKJCKoeZsS7MjPRgbqILM+PK/6unU/td8FTNlG0h4Nt0TczRd40fLnzcD9lPHxGJGX/9JNcQnQC8c/sQLwUAKZauHhi1w592/irmaUIO7oalIjYpF7HP85BTUMpreyIAxoY6sDDRg7mJHixM9GBhqv/i/+rBzckCZsaqdRskwwD/PkhEZFw2ktILkZxZiKKSCthbGcLB2ggO1kZoaGOMTl4OSn3Fc05+Ka7cTUBiWgGSMwqRnFEIHW0tNLCp/G9waWiGnm0bKf15FVKZHJFx2QiOSq/835N0BEdlICuvpF5xdHW0YG6shyYNTeHjZotWbjbwcbNBSxcr6Ooo95+BshBrVS4EZBihM6mejrEZ+v52Dhfm90FuXITQ6QCVffo7c/LVFQCsDwAixcypKUbtugR9c3qSnaoIjcnEj1sD8feVJ5DLledvp0gEeDSxgq+XAzq3agBfLwc0dVTOojIhNR/bTjzGbr8wJKTm1/p5O0tDzB7phTmjvDld3kLa6esx2HUmFGcDYlFeUfOhMBYmehjb1w2zR3rDx015jq7OyS/F8atPcdA/AgHBSSgr5364TVm5DKlZRUjNKsKtkP8OfNGWiOHe2BI+bjbwaW6Lth626OTpALFYud92hSLRFqOiXC50GjXSM7VEvz/O4/xHvZH/nPyNt/VUZZ8uYt4qo0QikQGAPFRfHPDOtGFjjN13rdqbBDXN8VkDEB9wkdWzJ9YMx/AeroQzeteW448w96eLSl2Vv87a3AC9Ozhi3uhW6OqjHD9nAcFJGPrpCeTk13/ERKIlxvK5nbF4RgceMqs7mZzB/FWXsenvkHo/qy0RY8t3fTFtSEseMqubwuIKnLoejUP+kfAPfIYKqXCdjIO1Ecb3a46JA9wFudTr5LVojPiM3dCzU5e+GLntPOGM/lNSJENpMT+nDZJWlJGE8x/1RmFKnJBpSAGYMgxT/PovVjV22BICdv5Gdg0xatcl2vmrkBP/PMWHKy+pTOcPABk5xTh4IRLdZh2Cz4Q92H7yMUrKpILl43cjBn3mHWXV+QOVQ9Tf/nUDK3feIZxZ3TEMMOzTE6w6fwCokMoxfdkF/LKb04InVvIKy/DtXzdg13cDJn13Fn43YgTt/AEgOaMQa/fdQ5uJe+Exeif8bsQImo8yUfZ1AK8ztG6A/n+ch6F1AyHTkKCyb39DVQWAYPvsDK3sMGb3ZZg2JHvbEsUfmZzBjOUXIFOiIf/6Co5Kx6wf/dFowGZ8ve5fZOQU1/4QYUs23kRpOfcCZPH6G1iz7x6BjOov+Ek6zgbEco7z8667Cvt5Ki2X4te9QWgyZCt+2nEHRSUVCmm3viKeZWHIJyfw/mI/pGcr/udT2Wgp8U6AqhjZO6PfnxegbyHo9ezv9O1KUwBIdPUwbONJmDk1FaJ5iqW7oSnILSgTOg0isvJKsGrXXbQcuwunryvubSsztwTBT9KJxfv8t2sKzf8l/8B3FhmzkpNfinvh5K+TfZ1czmDbycdoOnw7vvj9OrJZjrwo2iH/SLiP2oErd8ndq6KKxGKRyq2PMGnoil4/H4OWjp5QKdSpABBkAq7P/7bB1rOdEE1THAQ+Sq79QyomPbsYwxadwKwf/VFYzP8b4a2QZOLTJ/NXXVZI7q97fVEbVzeDk4jFeltRSQVGfH4SH/zoj+dpBby1w5fs/FKM+eo0YpPyhE5FUKo2CgAAVu5t0PnrTUI1r5xTAO3nfIPmg99XdLMUAeVS1ViIw8b2k4/hPX4Xbobw1xkBQHEp+Y46Ma0ASzYFEI9bk9pW+9crFk8/V8/TCtBl5kFBRkhIyskvxYjPTvLys6MqVGkdwOua9BkHr8lfCtF0zSMAIpHIBoBC9+G49BqKzp/8qMgmKarOYpPy0G3WIRy+GCl0KvX258EHeBhFbmpB1d0LT0X7KfsQrCZ/Jo+eZuCnHcIt+hSaMt4JUFetP1gGxy5DFN2szYs+/pW3RwAU+vZv1cwTA1bvhdJd70RRr5HLGUxdeh7X7ycKnUq9yOQM5vzvolKdySCUE/88RbdZh5CSWSR0KkRdvhMvdAqCUeUCACIRui7ZAfMmCp9xf6OPf7sAUFg2+hbWGLbxJLQNlOfwEoqqTlm5DMM/O4nQmEyhU6mXoLBU7DgdKnQagoqMy8bEb88Kus2TLw8i0zR2GkDVFgG+TVvfCL1W/Q09M4UedvdGHy/ICIBILMbg3w/DpIGzIpqjKCJyC8owYMExlVs49sOWW0ROsVNFUpkcU5acU8vOH6g8OyE4KkPoNAQj1lLtIsDIzgk9ftgPkVhhx3nXOAKgkAKg9bRP0bB9d0U0RVFEPU8rwMCFx1SqQ01MK8CW4+wO51F1/9t+G0Fh/G4pFJqNhYHQKQhG1UcBAMDOpxtajFuoqOaqLgBEIpEIQAu+W7ds2pIu+qNU2uPoTGxWsQ71px13NG6o+F54KlZsuy10GrzSlojh7GAidBqCEavJ/Uk+HyyDeRPeu18AaPGirwfw5ghAYwCGfLYslmhjwC+7oaWjWjezUdTbVu64o1LDyqlZRVh/+KHQaShMabkUU5ach1Sm3BfGcOXS0AwSLeW9DZJvWio+BfCSlrYuun63A2KJNt9NGaKyrwfwZgHQnO+WOy1cBmv3Vnw3Q1G8S80qwl9HVKtD/WV3EPKLyoVOQyH2+IUj4lmW0GnwbnTvZkKnICh1mAJ4yaKpF1rN+F4RTb3q618vAJz5bNHBxxftZn7BZxMUpVC/7A5S+Gl7XGTlleC3/cLcE6Bo+86FK7Q9IwNtuDlZoGdbR0wa6IE5o7wxtLsL2nrYwd7KEFo8dFR6OhIsGNeaeFxVouqLAN/mOXERbFp25LsZp5f/IKnqF0nT1jdEv1W7INJSkwkbihftWtjhl4/ZLQ7NLyxHVl4JsvJKEJ2Yi2v3EhEVn004wzdl5BRj3eEH+Ga6sFfw1sfaffewYHxrWJgIdh457+KS8xAQ/JzXNnq0aYR5Y1rB09UKDWyMYWKoU+PnZXIGaVlFSEgtwLmAWBy9HIXIOG4/n5MHeWj0AkBAfdYAvCQSa6Hrd9txalp7SEt5O7NCsQVAh3nfwszRha/wlJqwMNFDjzaNiMVLzSrCHr8wrNl3j7cb1P48qFoFQH5ROX7ZfRc/L+gmdCq82X8+gperqfV0JJgwwB0fv98aXk2t6/WsllgEB2sjOFgboaOnPX6Y1xmPozNx9FIUq2LAztIQ387k/U1R6anTFMBLxg2awHvq17i/mbfpAMeX/8D7FICJgxN8pn7MR2iKqpGdpSG+nNoecX6zsXxuZ14OnEzNKkKYih0OtO7QQ6Sp8ZWye8+SH/6fPrQlEs/PwfYl/erd+VfH09UKP8zrjIhjM/DgwBRMH9oSujq1v9KaGevC/6/RcLLX3NX/r1O3aQAA8Bg7H0Z2jrV/kJ1XL/viqn6RpC6f/QSJrvoON1LKT19XgiUfdMLRVUOhryup/YF6+ueeah0RXFxagZU71HN73L3wVOJTPz8v6IYdS/vDykyfaNzX+bjZYMfS/kg4OwfL53aGnWXVG7IM9bVx9o9RxIoQdaCOowBaOnpoPYe37fJvFgAikUgPgC3pVuy8O8Bt4DjSYSmKlVG9muHwz+Qv4Pjnnurdzb7pWIjKnWhYF6Rv+ZsxzBNfTWtPNGZNbCwMsOSDTog/Oxv7VgzCpIEeaOVmgzmjvHH812FI9p8HX28HheWjCtR1aVmTXmNg7dGOj9D2IpFIG/hvDYAjAOJlVPevVtOLfiilMqSbC+aNboWNfwcTi3ntXiIYRrV+1MvKZfhxWyA2f9tX6FSIik/NJxbL3soQv3/ek1i8+tDR1sLEAe6YOMBdkPZViTpOAQAARCK0m78K5z58j3RkMYCGAJ69nAIgPvzftN8oOLTuTDosRXG2ZlEPWJuTWz2dnV+KkCeqd8XsjlOhiE3KEzoNopLSyY1qTB7UAsYGNa/up4SnjlMAL9l4doJzjxF8hHYC/lsD4Ewysliija6f/0wyJEURo68rwfShZC++VLV1AEDlRTnLNt8UOg2inqcVEos1to8bsVgUf9R2BOCFNvP+x8cJgW8UAERHANwGjoVpoyYkQ1IUUXNGeRMdso+MU81T5/afj1CrE/OeExwBaOZkTiwWxR91OwvgbcYOjdH4vdGkwzoCPBUAdNsfpeyaNDCFs4MpsXjZ+aXEYimSXM5gySb1GAXILShDUQmZkxmNDXTo8L+KUOcpgJc8xi4gHZKfEYAGbbrAtkUbUuEoijfO9uQKgKxc1SwAAODYlScIjlK9NQxvI/n2X1hSjrzCMmLxKH6p+zSApZsPbL18SYZ8YwSA2KZS+vZPqYrGDUiOAJQQi6VoDAN8v1H1RwEycsgdbsQwwN2wVGLxKH7RUYB6swH+KwAsSEQ0aeAM117DSISiKN41JjkFkKe6IwAA4HcjBrcfpwidBicWJmQP6rn9OJloPIo/6noWwOscuw6BkR2xwXpLgHAB0GrSfHrhD6UynB3IHaWapeIFAAB8t+GG0ClwYm9V9el5bJ35NwYyOQ+XClDEiTRgBEAk1oL76A9JhassAEQikQnevBSIFYmeAVqOnsE5K4pSFJJTAMWlFSgrlxGLJ4QrdxNU8lTDl6zNDSDREtf+wToKCkvF4vWqXRRpClU6hIuLpoOnQqJH5AwTfZFIpC/Gi0qAK6cufaBrTO4LlaL4RnIRIKC6OwFe992GAKFTYE0kAmwtyV6P+8vuuzjxz1OiMSmKLR1DUzi060UqnKUYhIb/XejcP6ViDPXJHq5RVudfgjQAACAASURBVC4lGk8It0KScf7mM6HTYM3eyoh4zGlLzyPwEV0PoMxEmjIEgMq1AISQKQBEWlpo0mMQgXwoihLadxsCwKjo1DfpdQAAkF9Ujm6zDmHlzjuQ0zUBSkmD+n809B0IEZnTjyyJTAE4tO4MfXMrAvlQFCW0B5FpKjvszddNeVKZHIvX30Dfj44iJbOIlzYoDjSoANAztYSNZycSociMANCtfxSlXpZsuqmSb7uj3mvGa/wrdxPgOXYXft51B/lF5by2RdWdJo0AAIBjt6EkwpApAFx6EUmGoiglERaTiYP+kUKnUW9NHc3h3YzYuWZVysorwTfrbsBx4GZ8+9cNogcQUexo0hoAAHDsMphEGO5TAJauHvTiH4pSQ8s234RUJhc6jXob3Usxt/jlFZbhpx134Dx4Kxb8cgXRibkKaZd6l4b1/zB2aAwzZ3euYbiPANi2pOf+U5Q6ik7Mxe4zYUKnUW+jejVVaHvFpRVYf/gh3EZux7BFJ3DtvupdDa3yNKwAAADL5q05hxAD4LQZ2rp5K65JUBSlpH7YGojyCtU64Mi9sSXv0wBVkcsZnL4eg56zD6P1hD3YezZc5f7sVJWmjQAAgEVTb64hTMUAdLlEsPHw4ZoERVFKKiE1H1uOPxI6jXpb/UkPQdt/GJWOKUvOwXnwFvxv+21k5anuZVGqQKSBQwCW3AsAXTEATpdeWzX34poERVFK7H/bb6OkTLUOOerTwQljeitmLUBNUjKL8N2GADQasBlzf7qEyLhsoVNST5rX/8PClXPfq8NpBMDEwQl6JuZck6AoihCXhmawNid7HG5qVhHWH35INKYirF3UA0YGZE97ZKukTIrNx0LgMXoH3l/sh8S0AqFTUiuaOAWgY2wGIztHLiG4jQBYu3MegqAoiiAjA218O7Mj8birdt1FQbFq7XtvaGuMJR/4Cp3GGxgGOOQfCbcR27Fs8y0Ul1YInZLa0MQiwMKVUx+sIwGHAqA4KwOB65dzSYCqg7yEGKFToFTIvNHe+P3AfcQl5xGLmZVXgt/238eSD4icQKYwn0xog2NXnuBOaIrQqbyhpEyK5VtuYcepx1i1sDve799c6JSIykuIUXjfUFosh8qeYc1SSW46l8d1JOAwBZASHIiU4EAuCVAURZiOthZ+mNsZU5acIxp37b57WDDOB+YmekTj8klbIsaF9aPRa+4RPIhMEzqddySmFWDCt37468hD/P55T7T1sBM6JSJyE2Jwe/0PQqdB1Yz7IkCKopTPxAHu8HQlez9HXmEZVu8JIhpTEcyMdXFxw2h4NVX81sC6uhmShPZT9mHG8gtIzaJ3DVAKoUMLAIpSQ2KxCCsXdCMe989DD5CerXpH31qa6uPyxjHwaML57jPeMAyw83Qomg3fjlW77qKsnJ4hQPGKFgAUpa4GdWmCrj4NicYsKqnAyp13iMZUFGtzA/yzeRyG9XAVOpUaFRSX4+t1/6LFmJ149DRD6HQo9cVtGyBFUcrtZx5GATb9HYLnKrqNzcbCACfXDMfRVUNhZ2kodDo1inmei26zDtGjhSm+0DUAFKXOfL0diL/xlpZLsWL7baIxFW1072YI/3s6Zg73FDqVGuUVlqH//L9x9HKU0KlQ6odOAVCUuvvpo67QEpPdJL3j1GPEJpHbZigEcxM9bPu+H65uHgvXRmZCp1OtsnIZxn/jp5KHMVFKTUcsdAYURfHLo4klpgxuQTRmhVSO5VtuEY0plJ5tHfHo8DR8ObU9JFrK+ZUolzNY8MsV/LRDNddfUMpJDEC1jveiKKrels/tDF0dLaIx958LV5uz7fV1JVi1sBvu7p2E1s1thU6nWt9vDMDtx8p1qBGlssppAUBRGqCRrTHmjyV7c6dMzmDppptEYwrNx80G9/ZNxrHVw5TyUB65nMH0ZedRWq5alzNRSqlcDKBM6CwoiuLfNzM6wNSI7Kafo5ejEPJEvbaqiUTAyPeaImjvJFzcMAY923K6cIW4yLhsLNmoXoUXJYgyOgJAURrC0lQfX05tTzQmw1QOS6urPh2ccHXzWATumoih3V2U5sKZNfvu0akAiis6AkBRmuSTCa2J738/82+M0l22Q1pHT3ucWjsCjw5Pw8QB7oIvFqRTARQBdA0ARWkSAz1tLJ1N/orc7zao7yjA61q6WGHfikF4cmIm5o72Jr6wsj4i47Kx7hDdGkixVi4BhwLAvlUnOHXpQzAfqiqRp/cjl14JTBEya4Qn1uwLQnRiLrGYl+/Ew8pMn1g8Zde4gSk2ftMH38/qhDX77mHzsRAUlVQoPI9dZ0LxxZR2Cm+3NmaOLmg+dKLiGmSA0mLNuzshKegyMkJZbw0tk4DDFICBpTU6zV/K9nGqjlKCb9MCgCJGoiXG/z7qinFfnyEaNzO3hGg8VeBgbYQ1n/bAN9M74PcD97H+8EPkFSpuVjU8NgsPItOUbuuiqaOLQvsGhgFyMzVvMDv76SMuj3ObAsiICOHSOEVRAhnT2w1t3JWr01BlVmb6WPFhF8SfnY0VH3ZR6GjIHr8whbWlrBiGEToFQWRHc+qDuRUA+cnxKM3P4ZIARVECEInAy3XBms7USBffzuyIOL/ZWPNpD1iY6PHe5kH/SEhlct7bUWaa2P+XF+SiMDWBS4gyzrsAMiM5DUFQFCWQPh2c0Ku9cu1xVxeG+tpYNKktQo9Ox6AuTXhtKz27GP6Bcby2ofQ0sADIjubc93LfBpgeTlehUpSq+nlBN6XZ266O7K0M4ffHSGxf0g8mhvzdu6bp0wCaOAKQ9ZTzFHyZGACnpcAZkcFck6AoSiBtPewwupeb0GmovRnDPBG4ayJvawPOBsTyEldVaOIagGzuBUCeGACn2zzSQu9zTYKiKAH976Mugh9sowk8mljC/6/RxI9jBoCikgrk5JcSj6sqNLD/R1bkA84hOBcAWdHhyEvU7OqTolRZU0dzzBzuKXQaGqF1c1uc/XMkDPS0icdOzigkHlNlaFgBUJD8DLlxEVzDcC8AACDmymmuISiKEtDS2b68dErUuzp7N8CyOeRPY0zS4AJA00YAEgL8SIQhUwBEXzlFIBeKooRib2WIj99vLXQaGmP+OB/YW5G9k0GTRwAYDRsCSPiXyEs3mQIg+cFNlORkEsiHohQnt4DsnKmqv0F/Na29QvatU4C+rgSLZ3QkGjMpXXMLAE3q/0vzspD+OJBEKDIFACOTIfbaWQL5UJTixKXkE41nruKdp6mRLr6Z0UHoNDTG7JFeMDYgtzVQkwsATZoCeH7rHBg5kXsPyBQAABBDpwEoFfMsKY9YLGMDHWhLVH8l/fxxPmhoayx0GhpBR1sLbs4WxOIlZ9ICQBMk3CB2hwe5AiA+4BLKCsh9oVIU30gWAJZqchOeno4Ey3lYoEZVrTnBAiA7T4O3Aco1owIoL8pDctAVUuGyxADyAXAeT5CWFiP07x3cU6IoBYlLIVcAqNPc+dQhLeHe2FLoNDQCyQLAwlR9fgbrSybTjALgqd9uSEuLSYQqYRimRMxUHqFE5Eaf4H3rwcg0705mSjWRHAFQpy9fLbEIP83vKnQaRBSXVuDynXhEPMtSymFikj831moyCsWGXAMKAEYuQ8TfG0iFywIAyYt/yQZgxTViflIcoq+cQtO+I7mGoijePUumIwDVGd7DFR097XH7cYrQqbCy92w4dvuFIiA4CWXllS8llqb6+Hp6e3z8fhulWa+RklFELJa1uQGxWKqEYTRjDUDCjTMoTI0nFS4LAF7+LUglFfXh7j9IhaIo3jyMSie6atrSVP3evlYt7C50Cqz8sDUQU5acw5W7Ca86fwDIyivBF79fh+fYXbgbphyFDcnDezS1ANCEt38ACD+yjmS4dOC/AoBYWZF0PwBpYfR+AEq5bThC9hZL72bWROMpg26tG2JgZ36vsiXts9+uYemmmzV+Jio+Gz0+OIyT16IVlFX1/n2QSCyWtbn6FaF1oQkFQFbUQ6Q9ukUyZALAQwEA0FEASrmlZRfjwIVIojF7tnUkGk9ZrFzQFWKxatwX/MfBB1i7716dPltSJsWoL07h9wPCvaw8jEpHdCKny1jfoKkjADIN2AFA+O0feNHn81IARJ07Qi8IopTWzOUXUFxaQSxeAxsjNHMyJxZPmXg1tcaE/u5Cp1Gr7PxSLN9SvzckuZzBp2v+wcerr0IuQCfy2/66FSt11cxRPX8Ga0PmTBzlVZD8DM+u/k067BsjAHEkI8ulFbjx69ckQ1IUEesOPSB+d7q6vv2/9MPcztDR1hI6jRr9uDWQ9XW4fx56gGGLTiK3oIxwVtXzuxGDvWfDicVr7myBxg1MicVTJeo+BXB/47eQS8m9sLzA3wgAADz1P4bkBzXPxVGUIq3ceQcf/3qVeNyebRsRj6lMGjcwxdxR3kKnUa2k9EL8xXFNh9+NGLSeuAf3I9IIZVW9+xFpmLHcn2jMQV1Ua60GSepcAKQ/DkTctRN8hH6jAEgED9cpXF/1hWbsz6CUWlxyHiZ864fF62/w8uOo7iMAAPDdrI4wMlDOy44CHyWjQirnHOdZUh58px/A8i23UFBcTiCzd528Fo3uHxxCRg6Rw1xeGdRVgwsAdV0DwDAIWv8VH5HlAJ4DLwoAhmFKARAvfVND7iDq3GHSYSmqVqXlUly7n4gZyy+g6fDtOEh40d9Lro3MNGLo1drcAJ9Pbid0GlUKeZpOLFZ5hQzLNt9C48FbsXpPEErKpJxjMgxw+noMusw4iBGfnURRCdnhXFMjXXRp1ZBoTFUhlzNq+44Ze+UoMsKD+AidwjBMBfDfQUBA5ZCAHemWAtYshkvv4ZDoqtdBKRR5iWkF2PR3CKtn84vKkJVXiqy8EkQn5uL24+Q39oDz5cup7XlvQ1l8Nqkd/joSTPztlavgqAziMbPySvDlH9fx694gDO/hisFdXdCrvWO9rnwur5Bh//kIrN4ThIhnWcRzfKlvR2elOdhI0dR1AaCsvBQPNn/PV/hXU/5vFwDE7wLNT47Hw91/oN1sXoYyKDUSHpuFeSsvCZ1GnTVpYIrpQ1sKnYbCGBlo4/tZHbFwNfl1FFzoaPPX+aVnF2PL8UfYcvwR9HUl6NnWEZ5NrWBnaQg7S0PYWxnCzFgPyRmFiEvJQ1xyPuKSK//v08Qc1gsT62PSQA/e21BW6jr8H35kPQpTE/gKX20BwIs7G/+Hpv1Hw8zRha8mKErhlsz2hURLs9685ozyxm8H7hO9R4Err6bWOH71Ke/tlJRJce5mLM7dVJ4tzt1aN8TQ7pr7vaqOCwALkmIRsvtnPpt4VVm8/u3FWwFQUVIE/6+m0YuCKLXRzMlcI9+8dLS18OO8LkKn8Qavpup3CmNdiETAr5/0EDoNQalbAcDIZbixYiakpeTuiKjCq77+9QKA17I2+eEtBG1fzWcTFKUwS2f7QktFTsgj7f1+zZWq0+3WuiFMjXSFTkPh3u/njnYtiC/bUinq9k75eP9apIfe5ruZKguAML5bDfxzGTIigvluhqJ41bejM8b3bS50GoIRi0VYuUB5rgu2NNXHsjm+QqehUHo6EqX6/4FQ1GkNQPbTRwje8aMimnq1JepVAcAwTAKAAj5blUsrcP7LqZCVK+7ELYoiycfNBn+vHqoy5+PzZWDnJujeRnkOQJo/zgfujS2FTkNhvp3ZEY52JkKnITh1mQKQVZThxooZfJz497YiAM9e/svbK5h4HwXIehqKm7/ztr2Bonjj7GCKc+tGwdhAR+hUlMLPC7oJncIrEi0xtn3fr17b9FTV7JFe+G5WR6HTEJy6dP4A8HDrMuTE8t79AkAYw/x3csLbBUCoIjJ4sOs3PL97XRFNURQRFiZ6uLB+FOwsDYVORWl09LTH8B6uQqfxiq+3A87+ORKG+upbBIzt44aN3/QROg2loC7D/6kP/0XY4T8V1dzj1/9FkAKAkcvh98k45CfFKaI5iuLExFAHZ34fCTcnC6FTUTo/ze+qVIshe7RphHN/jlLaY4u56NfJGXt/HKjx008vqcMCwMLUeFxbMhGMnPtR1nVUYwGgkDEIACjJzsCpecNRUVyoqCYpqt66t2mER4enwdfbQehUlJJ7Y0tMHaJchyF1a90QF/8ao1Zz5L7eDjj+6zClv5VRkWQVCus0eVFRUogrX41GaW6mIpt94yVfkBGAlzKfPMb5LybTC4NUmKGazrnq6mhh9SfdcXXTWDjZ89uRmJuQOybbwkSfWKy6Wj7Hl/i6CK7/HZ28HPD4yDTMHO5JKCNhiMUifDGlHa5uGqcR6xvqQypV4X6DYXDjhxnIiVVolwvUNALAMEwqAP4Ora5CzJXTdFGgClOmleCkeDW1RtDeyfh8cjuFDLd2adWA2Jtdn45OROLUR0NbY2xcTHZeuk8H7v8dJoY62PZ9P5z9cyQcrI0IZKVYjRuY4tqWcfjl4+7Q1aFv/q9jGECmwgXAg63LkBBwRtHNpjMM88bNWVWdY6rwkuTu5pWI9Duo6GYpAjxdrdHQ1ljoNIho3dwWO5f1R9DeSfB0tVJYu4b62ujs3YBIrIGdhbkWduIAd0weROZkxObOFkRvWBzYuQlCj0zDl1Pbq8wOjpnDPRFyaCq6+mjmLX+1UeXOP/bSYTza+4sQTT9++xeUogAAgEvfzkLaY16uPqR4JBIBx1cPU9mV19oSMcb1bY6AHe/j/v7JmDakpSDzrFu+68up0xOJgLWLesK7mXAn9G1a3AfjOB6QZG9liEMrhxDK6D/mJnpYtbAb4s/Oxg/zOsPSVPFTJXXRo00j+P81Gtu+76cyxYoQpCo6/58ZcR83f54rVPPv9O1VFQAKWwj4OmlZKU7NG47ceP4v9aDIatfCDsdWD4OJoWp8YenpSNClVQMsn9sZcX6zcWjlYGJv4Gy5NjLDzR0TWHXgOtpa2LdiED6d2IaHzOrOQE8bh1YOxh9fvMfqelr3xpYI3DWR1yLG3EQP38/qhPizs7Hm0x5o7iz8zg59XQk+GOGFR4en4Z8t49C3o7PQKSk9VRwByH8ejStfj4KsnP8bIqvxzgiApC4fUpSizFQcndobY/ddg2nDxkKlQbHQr5Mz4vxm4/cD9/HHwQfIK1Se0x7trQzh690Avl4O6NyqAXzcbJRyNbW9lSHu75+Cszdise3kI5wLiIWshr3Obk4WmDncE1MGt4CthYECM63ZwvGtMbyHK/aeDcduvzA8Tcip9rNaYhEGdG6CmcM9MbhrE4Xdrmior41Fk9pi0aS2eBKfg1PXo3HqWjQCHycrbH+5m5MFZgxriVkjvGBBcCGoJpBWqFYBUJgSB/+F/VGSnSZkGu/07SLmrRX4IpHIAEAeqi4OFMK0YWOM3XcNRnZ0/gsAjs8agPiAi6yePbFmuMIPaykqqUBkXDZik3IR+zwPOQX8VrwiiGBsqAMLEz2Ym+jCwlQfFiZ6lf8z1VPZi2Iyc0vwNCEHiWkFeJ5WgMKSCjSwNoKjvQmc7EzQzMlc6BTrJOJZFuJT8pGcUYikjELo6UjQyNYYji/+G6zMlGc4Pj27GOdvPcODiDSExmQiNCYT6dnFnOPq6UjQ1sP2VSHq6+0Aa3PlKdqqcvJaNEZ8dpLVs05d+mLktvOEM6oklzPIy+L9yFxiijKScP6j3ihMiRMyDSkAU4Zh3vhhfqeTZximWCQSPQLQWlGZvS3v+bPKkYD912Bopdm3XakiQ31ttHG3RRt3W6FTUWlWZvqwMtNHJ6ET4ci9saXKnNNvY2GAqYNbYOrgFq9+LSOnGKExmYh4lo3svFLkF5Uhv6gcBUXlyC8qR35RGcQiESxMXxad+pWFqEllIepob4xWzZRz1EkVyVTo7b8kOw3+C/sL3fkDwKO3O3+g+rf8QAhYAABAbvxTHJvWB2P2/gN9c8WtyKYoinqdtbkBerZ1RM+2jkKnQkF19v+X5mXB/+MByH8eLXQqAHCrql+sbsItkMdE6iwrOhzHZvRDaX71c4gURVGU5lCFHQDlBbm4+OlA5MZFCJ3KS1X26bwUAE16Duby+BsyIoJxfOYAlOZlE4tJURRFqSZl3wFQlp+Di58NRvbTR8RiOnUfzjVE3QsAhmFiAaRX9Xt1YduyLVpP/Zjt4+9IexyEwxO6oSAlgVhMiqIoSrXIpIxSnxxflJaIcx++h8yI+8RieoyZD+sW7bmESGMY5llVv1HTnhvWowDxNy+h+9dr4D50ItsQ78iOicCh8V2Q+USwXYoURVGUgJR5/j8nNhRn5/VAXnwksZhN+o5H+wW/IPneVS5hqu3LayoAbrNtLTXkDsqLCtB35Q44d+vPNsw7CtOScGRidzwPuk4sJkVRFKUalPUGwNTgGzj/YW8UZyQTi9mgYz90+WYLZNJypIXc5BKKVQHAegRALpMi8c41iLUkGPLnUdi3IreRqawgD8dnDsBT/2PEYlIURVHKTxlHAOKuncClRUNQXpRHLKZ1yw7o+eMBiCXayHh8G7KyEi7hWBUAQag8PICV+JuVB9dI9AwwfMsZWLq2qOWJupOVl+Hsp+MRvG89sZgURVGU8lLGGwAjjm3A9aWTIKsgd/KpWWMP9F51AhK9yoOiOA7/VwC4V91vVlsAvDg0gPUyxviAS6/+Wc/EHCO3n4eJA7mrShm5HP+s+BgBa76BUq8KoSiKojiTSZVo+J9hcH/Td7jz+2dg5OTyMrRthL5rzkDX5L9TPlPu/8MlZAjDMNUOH9R28HaVhwfURW5CNPKe/7fw0Mi2AUbuuAB9C7IXfQRt/QUn5w1V67MCxFrsTxArr5ARzISiKE3B5buDy3dWdZTl/P/ywjxc/moUHu9fQzSunqkl+q71g4G1wxttZUY+4BK2xj68tgKA09hD/M1Lb/y7uXMzjNjiB20DIy5h3/Hs2jkcGNUeGRHBROMqC31z9kXTo6cZBDOhKEpThMVksn6Wy3dWdZShAMiJeYwzs3zxPJDsPQfa+kbo/etpmDo2e+PXUx/+C0bO6SWuxtWDdSkA2K8DqOICG9uWbTH0rxPQ0iZ7dWxeYiwOvd8F4Sf3EI2rDAyt2d+HcC88lWAmFEVpigeRrI+C4fSdVR2h5/9jLh7E2bk9UJAUSzSuWFsHPX86DKvm756+z3H+Xw7gSo1t1/SbDMPkAbjDtvXEO/+Akb1bvTh2eg/DNp0mPhIgLS2B/9fTcWXpPMgqyonGFpKBJftLde5HCHr9JEVRKupBJPvvDi7fWVWRSRmFXdP8Nrm0And+X4QbP86AtJT7zZCv0zYwRu9Vx+HQ9r0qfz+FWwHwgGGYrJo+UJfLt9ndQwugLD8XqaFBVf6eU+c+GLP3KvEfFAB4dHgLjkzsjoKUROKxhcClms7MLYF/YByxXCiKUn/X7iciOaOQ9fOkRwAqyoVZAFiSlYoLC/oi4thG4rH1LWzQf91FOLTrVeXvF2UkIS/hCZcmau27eS0AgDd3A7zNtkUbjD8UADNH8vfVpz66i/0j2yLhVo0jICrBtmUbTs9/8KM/8ovUZ0SEoij+FBSXY/qyC5xicP3Oelt5meILgLSQAJye0RHpoazPxKuWSUMXDNx4DZbNWlX7mZR7nFb/A4QKgCAAuWwzeHsh4NtMGzXB+EMBsG3Zlm0T1SrJycSxmf3w76rPISsnt09T0cycmsK0YWPWzyemFWDRWs4/TBRFaYDP1l5DXDL7Q21MGzaGmVNTYvnI5YxC5//lFeV4sGUpLizsj5Js8lOoVu5tMHDjNRg71PydznH4vxB12MVXawHAMIwMtSwkqElqyB2UF+bX+Bl9C2uM2XsVzl37sW2megyD+zt/w/6R7ZAe/pB8fAVx6tKX0/PbTz7G9xsDUKFMe2kpilIaFVI5vt8YgK0nuN1ix/W76m0VZYrr/HNiQ+E3pyse7f2F6+r7KjXo0Bf9//SHnplVrZ9N5rb//xrDMBW1faguIwAA4M82i5fHAtdGW98QwzadhsfwyWybqlFWdBgOju2Eu5tXVrkwUdk5d+FeHK3YdhvtJu9FcBT71b0URamf4Kh0tJu8Fyu2cR/uJvFd9TpFzP8zcjlCD/4Gv1ldiF7j+zrXAZPQa9UxSPQMa/1s7rNwlGRx2sFVp6l7EVOHU/REIpETgDi2mXhPmIf3ltT92N6ANd8gaOsvbJurlX2rTuj/yy5e1h7wRVpagu29mqA4i3vnrS0RY0g3F7RrYYe27nZo424LcxM9AllSFKUKcvJLcT8iDfciUhEUlooz/8YQGR00sLTBzCuxkOjpE8iy8pDX3Ex+1y8VJD9DwP9mIe0R63PvauU56XO0mfNjnT8femAt7m38lkuTzRmGiartQ3UqAABAJBJFAWhW6werYOboiukXa83lDcH71uPaT58SPWbxddr6huj29a/wGjebl/h8uLt5JW7+9p3QaVAURVWp86cr0H7ON8TilZfJUZTP+iiaWj05vR1B679GRQn7HQ81EYnFaL9wNdxHfViv587M7ISsJ6wPtktgGKZO5+7XdQoA4LAb4O1jgeui1aT5GLj2ILR0dNk2W6OKkiJcWToPJ+cMRmFaEi9tkOY94UPoGJkInQZFUdQ7dIxM4D2hfh1dbSp4Wv1fnJGMy1+OwK3V83nr/LW0ddF9+b56d/75z2O4dP5APfrq+hQArNcBAED0xeP1fqZZ/9EYuf088fsDXvfs+nnsHtgCD3b9DrmMv0qTBF1jU3i/P1foNCiKot7h/f5c6BqbEo1Jev5fLpMi7Mg6nJjUCs8DuW11rImeuTX6rD0D5x4j6v1s3NW/uTZf5wKgPlMAegAyALA6vs/KzQuTT7FbhV+Ynoxzn01EUtC/rJ6vKys3L/Rauh4OrTvz2g4X5UUF2De8NfISyR5HSVEUxZZpoyaYdPIBdAyNicWUVshRkEvupSz9cSAC13yMnJjHxGJWxa5VV3Rftgf6luwOQzo1tR1yYkPZNi8FYMMwTJ1ux6vzCADDPacICgAAIABJREFUMKUA/NhmlRn1CJlR7FZXGtk4YMyuy5VzSyIR2xRqlRn1CIcndsfFxTNRksP+Igw+6RgaY8CveyHWkgidCkVRFMRaEgz4dS/Rzh8Ayglt/yvNy8LNlXNw7qNevHb+IrEY3lO/Rr8/zrPu/PPiI7l0/gBwpa6dP1C/KQAA4DQ2EX5qH+tnRVpa6PzpCozcxu+UABgGYcd3YVd/dzw+srVyGaqSsffuiI7zlwidBkVRFDrOXwJ7747E43Ie/mcYPDm9HScmeOLpuT28fpfrmVujz5oz8Jm1FCIx+6uQYy8f5ZpKvQLUeQoAAEQikQEqpwEM6pkUgMo3+VnX4iES17fueFNhejLOfzYJz4Ouc4pTF3beHdBr6V+w8fDhva36YGQynFk4GjFXTgudCkVRGsql11AM+fNviLTYd3pVkUkZ5OfUeo5NtbKfhiDw1wXICK/6LhqS7Hy6ofvS3azf+l93YqI3l/P/pQDsarsA6HX16okZhikGcK6+Wb1UmJ6MhNucjjcEUFlIjN51CR3mfcu5mKhNasgdHBjTAVeXf4TiLOW5WU+kpYXBfxyBS+9hQqdCUZQGcuk9DIP/OEK88wfYv/2XZKfj9pqPcWZWZ947f5FYDO9pi9Hv93NEOv/s6EdcL/+5Wp/OH6j/FADAcRog4tReLo+/ItLSgu/HP2DEtvMwsLQhErM6jEyGkIObsKN3UwSuW4byogJe26srsUQbg38/jKZ9RwqdCkVRGqRp35EY/PthiCXavMSv7/a/iuICPNz+I46N80DkyS28HOP7On0LG/Rd6wefmd9zGvJ/HYHV//WeP6jXFAAAiEQiI1ROA7A6Ok7bwAhzbiZDW7/24xDrqigjBec+m4jnd/mfEgAq7y7o+OF38Bo/h7e/APUhl0nx76ov8HDvOqVcs0BRlJoQieAzaT66ff0rbwuR5XIGeVl1G/6XSysQdWorQnatRGmuYhZu27XuXjnkb0H2Kvtj4zxQkFy/83JeIwVgzzBMvf4Q6l0AAIBIJDoBYHi9H3yh/y974D50ItvHq8TIZAj86wfc3fQTb6cHvs20URN0/mQF3AaO5XV3Ql3F37qMi9/MUJmDjSiKUh2GVnbou3IHP5e2vaasVI7iglq2/zEMnl39Gw+2LOXSadZL5Sr/b+A9bTHxqefMiPvwm92FS4jLDMP0qe9DbP8rlGIa4HUiLS34LlyOkdsuwNi+EfH4VclLjMW5zyZg/6j2SLjF+sJEYpx8e2Py6WC4D53I+9oIiqI0hEiEpv1GYfLpYN47f6D24f/ke1dxZpYvri+borDO39C2Efr+dhatZnzHy3frs6uKXf3/EtsRABNUTgPosGpUSwsfXIuHobU9m8drVVFciFt/LMHDfesVevOfk29v+H7yI+y82iuszerkPItC0LbViDi1D3Ip+9W0FEVpJrFEG80Hj0fbmZ/DsmlLhbTJMEBuVjlQRbeUGXEPD7YuQ3KQ4l62RGIteIz5CD6zltTpFj9WGAZHRzdDUfpzthFkqBz+z6jvg6wKAAAQiURnAAxm9TCAbl+tRpvpi9g+XidpYfdx+fu5SA9/wGs7b3Py7Y328xajYbvuCm23KoWpzxFycBPibvgjPeIhXSNAUVT1RCLYuPvAuWs/eI2fo7DR1JequvwnNfgGHu1ZpdCOHwAs3Xzg++UGWDZrxWs76aG3cW5eTy4hrjAM05vNg1wKgCkAdrN6GIC1eytMOnGf7eN1xshkeLh3HW79sQQVJUW8t/e6Bm26oP3cxQoZNquLkpxMJNy6gkeHNytswSRFUcqvYfvu8Bo3B46+vaBvbiVYHgW5FZBWVPZJSXcu4tGeVbxe01sViZ4hfD5YCo/RHxJb4V+TO398joi//+ISYi7DMJvZPMilADAEkAKA9fmPU86EKGxoqSAlAVd/WIDYf1ifZsyabYs2aD93MVx7D1OKxYJxN/xx4oOBrJ6V6Orho/u5SrH7gapd4PrluL3+B1bPdpy/BJ3mLyWcEcUHubQCf7Uxg7SslNXzI7aeE/xFRSZjkJ9VjoQbZxCy52dkRbG7O4aLRr4D0XHR7zC0VczIh6y8FEdGuqAsL5ttiHIADeq7+v8l1qsZGIYpAnCY7fMAt6OB68vY3hHDNp7C4D+PwsjGQWHtApVTEWcWjMKeId6I9Duo0HUJVbHzbMv6WWlZKdLDFDulQlFUzdLDHrDu/AFu3wkkMDIZwk4cwMmpbXH123EK7/z1Le3Q44f96LXqmMI6fwCIvXyES+cPAGfYdv4AhwLghR1cHo48c0BhW/Zeatp3JKaeC4P3xA8VvlI+KzoM5z+fhF0DKu8ZkJaWKLT9l/TMLGHm6ML6+eSHgQSzoSiKKy5/J80cXaBnZkkwm7qTlpbg8ZGt2DXAHVe+m4LcZ+GKTUAkgtvwDzBifzCceyr+QLXIYxu5huDUB3PqARmGCQQQyfb5wrQkJN65xiUFVnSMTPDe9+sw/mAArNy8FN5+bkIMLi+Zi63dHXFj9VfIT4pTeA62nu1YP5v8ULFzchRF1YzL30ku3wVsFaQk4MavX2Nrd0dcXjIXuQkxCs/BrLEHBm64ik6f/QkdQ1OFt58RegdZT4K5hEgG4M8lAIlXYE4VCB9nAtSVnXcHTDwehK6f/wyJHqv7jTgpzcvGve2/Ykefpjj90QgkBHK/J6GuuGxVTKEjABSlVLj8nVTktuXnd6/jzILR2N7bFfe2rUYpt+FvVrR09NB69nIM3XEbNi3J32JYVxHHOb/972YYhtN8MokCYA8qjyFkJfrSCUHnxMVaErSd9QWmnQ9Hi1HTebnYojaMXI6YK6dxbHof7BnsiZCDm1BRXMhrm3Ze7Kv+wvRk5CfHE8yGoii28pPjUZiezPp5Lt8FdSEtLUHo0e3YO8wHR6e8J9h3vkgshkv/iRixPwRek78UdCFzSXYa4q6d4BpmJ9cAnAsAhmHSAJxl+3x5UQGyYyO4psGZsX0j9P3fNkw5HQLXPqxPOeYsKzocV5d/hK3dHXF95SLkJkTz0o6Nuw+ns7zpKABFKQcufxfFWhLYuPNz1fnrw/yXvp+NzKhHvLRTF418B2Lozrvo+u02GNk5CpbHS09Ob4e8opxLiBsMwzzlmgepVXCcpgHSwznNgxBl4eKOIeuO4f3Dt9CwvXAH+ZQV5OHB7j+ws19zHJ81ABGn9xM9x0Cipw8rN0/Wzyc/oOsAKEoZcPm7aOXmCYmePrFcpGWleOp/DKc/HC7oMP9LNp6dMHDDVfRadQzmTVoIlsfr5DIpok5t4xqGU5/7EqnrnM4BSAPA6nqkgjTWRyDyxs67A8bsuYq4G/4IWLsYGRECFSkMg/iAi4gPuAiJngFcew9D8yET4dSlD+fbuOw82yE9nN12G7oTgKKUA5e/i3YEFgAycjkS71xD5Jn9eHrxOMoL8znH5Mq8SQu0nvMDGvmyO++ETwnXT6E4M4VLiAKwPPv/bUQKAIZhpCKRaA+AL9g8b91M8Svx68q5az84d+mLqHOHcfP375GXGCtYLtLSYkT6HUSk30HoW1ij2YAxcB86Efbe7Bay2Hm1x6PDW1g9mxEVgoqSIqLXOlMUVT8VJUXIiAph/TyXBYBpYfcReeYAos4eRlEGpw6NGCM7R/jMXIImfd9X2gvRCCz+O/LiHB7OSF7ovAMsCwC+F6FwJhLBbdB4NO03Co8Pb8XtDStQnJUmaEol2RkI2b8BIfs3wMzRBW6D34f7kAkwb+xW5xhc/twZmQypIXfRqCOnM6wpiuIgNeQupwV19f0OyE2IQZTfQUScOYCcZ1Gs2yVNz8wKXlO+QvPhsyHWZnVHnUJkRz9CWshNrmGIDP8DBAsAhmEiRSLRcQD1Ok3BqUtf6FtYk0qDV2KJNrwnfgiPkVPxYNfvuLf9V6UY7spNiMGdDStwZ8MK2LZsi+ZDJsBt0DgYWtnV+JyFiwe0DYxY7zhIfniLFgAUJSAu+/+1DYxg4eJR6+eKs9Lx5MJRRJ4+gJSQ26zb44O2vhFajP8YLcZ/DG0D1qfSK0zksU2cQzAMQ2wBFskRAAD4EEAPABZ1+bCOoTH6/MjqDgNBaesbosO8b+H9/lzc3bwSwfs3QFZeJnRaAIC00HtIC72Hf3/5Ao4deqL50Elw7TMcOobv/uUQicWwbdEGz4PYXQxEDwSiKGFxOgCoRZtqh8krSooQfekkIv0OIOHmZchlrHd680KsrQO3obPgPfVr6JmrxgtkeUEuYi4d4hpmPYlcXiJaADAMkyYSieYA2A+gxnEYsUQb7y39C8b2wm/JYEvPzBLdvvoVbWd9geB9fyHk4CaU5mYJnRaAyiH6+FuXEX/rMq4s04fLe0PQfMhEOHft98b+VzuvdqwLgNTgO5XXCyvBBUcUpXEYpvLvIEtvD//LZVLE37iIiDP7EXPlNKSlxVwzJE7H2Axuw2bBfdSHMLCyFzqdenl6djdkZZyOf88BsItMNpVIjwCAYZi/RSJRBCoPKahygsnavRX6/7xTkGN4+WBgaQvfj39A+zlfI+zEHjzY9Tty4zlv0SRGWlqCqHNHEHXuCPTMLOE2YAyaD5kABx9fTouASvNzkBUTAUvX2ocRKYoiKysmAqX5Oayff/l3P/nhLUSeOYAn54+iJIf1vTK8MnZoDI+x89F00FRI9FRv4TEjlyPyBOfR7i2kFv+9RLwAAACGYcJEIlEnAP0BdADQHpWnBT4E8OD9I4FLtLR1WvHRtpAkegbwfn8uvMbNRuw/fri/cy2S7t0QOq03lOZmIeTgJoQc3ASTBs5oxPGsg5SHgbQAoCgBcD2M69n1c7ix+ivkPX9GKCPyrFt2QMvxn8Cx61ClXdVfF4kBfihI5vTnLAXh4X+ApwIAAF6cUXwWVZwSuChKbgBAcXcBK5hILIZLr6Fw6TUUqY/u4v7OtXh68bjg1wC/LT8pDmEn4jjFSH54Cy3HzCSTEEVRdcZ1DU7Y8V1kEiFMJBbDsetQtBz/CaxbdhA6He4YBsE7/8c1ylGGYYgfmMNbAVCLwwBWAlDcxcsCsfNqj0G/HUJ+Uhwe7vkToX/vQHlRgdBpEUMPBKIoYajb3z2JniGaDpoKj7HzYezQWOh0iIn/9xSyozkfg7yWRC5vE2RMZa2bWArgTyHaFopJA2d0/2YtZl2LR9cvVsHIrqHQKRGR8yxKaRY+UpSmKM3NUqp9+FzoW9qh9ewfMPZ4NDp8skatOn8wDIJ3rOAaJYBhmHsk0nmbkJMqWwAIv4lewXSNTdF25ueYeTkaA1bvhY0HPxdxKJK6vYlQlLJTh79z5i6e6LJ4K8YcjYLX5C+gY2wmdErExf1zHDmxYVzD/EYil6oINQWAtW7i/EVR8q0APhMqByGJJdpoPmQCmg+ZgKSgfxF6bCee+h8jeuGPogRt/QVFGSlw8OkECxcPlV6sQ1HKipHLkR0TjuSHgQg/uVfodFiR6BnAqftwNB04BXathbtsTREYuZzE3P8zACcJpFMlwQqAF/4AsBCAcBczK4EG7bqhQbtueG/JOjy58DfCju9Sut0DNUl+cBPJDyqPt9Q1NoWdV3s4+PjC3qcT7L07QMfIROAMKUr1lBfmIyXkDlIeBiL54S2kPrqLsoI8odNixaF1ZzTpOwlOPUepxIl9JDy7+jdy4zhfdf8HwzByEvlURdACYK2bOHFRlHwngNlC5qEstA2M0GLkNLQYOQ25CdEIP74b4af2oiAlUejU6qysIA/xNy8h/uYlAJUrei1cPODg0wkOrX1h36ojzJ2bCZwlRSmfnLgnSAm+jeQHt5D8MBDZMeFg5Lx99/POyLYBPIZNhsfIqTCwc0VxgXKdJsgnRi5DCPe3/3wQPPe/KkKPAADACgBTAegKnYgyMXN0he8nP6LTwuVICLyCsOO7EHP5JKRlpUKnVi+MXI6sp6HIehqKx0e2AgD0za1g36oj7H06wcGnE+w820GiZyBwphSlONLSYqQ+DkLyw0CkPAxESvBtpT2Epz60dHTh2nsYWoycDkff3q+mA/OyKwTOTLFiLx1GXsITrmE2MAzD65YxwQuAF6MAWwAsEDoXZSQSi+HUuQ+cOvdBWX4uos4dRtjxXUh9dFfo1FgryclE7D9+iP3HDwAg1pLAurn3q4LA3qcTTBycBM6SosjJT45/MZRf2eFnRIYo3fn6XNh6tkOLkdPgNmgc9EzM3/i9slI55DJGoMwUj5HLELJrJdcwhQDWEEinRoIXAC/8BGAWAH2hE1FmuiZm8Bo/B17j5yArOhxhx3ch8vR+FGWmCp0aJ3KZFGlh95EWdh/B+yoPuzKycXgxSuALB5+OsG7uTUcJKJUgLS1GRmQIkh/eRsrDW0gJvo3C9GSh0yLOwNIW7sMmocXIqbB0bVHt50qLlesANL7F+B9A/vNormHWMwzD+5CQiGGUozJbFCVfDeBzofNQNXKZFHE3/BF2bCfiblyAtJTTZRPKSySCiYMTLF3dYdHEHRYu7q/+WddE/bYPkRK4fjlur/+B1bMd5y9Bp/lLCWekPsryc5EdG4Gs6Ahkx0S8+uf85PjKS7LUkERPH85d+6PFyGlw7tYfYq2a3yHLSuUaNfcvl0lxYoIX12N/CwE4MwzD+wEryjICAACrAMwFYCR0IqpErCVBkx6D0KTHIEhLixF3wx/Rl07g2bVznC4KUToMg/ykOOQnxeHZ9fNv/JahtT0sXJrD0sUDFi7/FQcGlrYCJUupk+KstP86+ZgIZMWEIzsmEkUZKUKnphB6JuZo3GMgXPuMgHPXfvUaidO4t//z+7h2/gCwThGdP6BEBcBaN3Hmoij5nwAWC52LqpLoGcC1zwi49hkBuUyK53euI/ryCcRcOY3CtCSh0+NNUUYKijJSkHj7nzd+Xc/EHBauHrBwaQ6LJu6wfPHPJvaO9Apj6k0Mg/yUBGTHRCIrOhzZsRHIjolEdnS4ehXSdWRk2wAuvYbCtfcINOzQvdY3/apo2ty/XFqBkN0/cw1TAAXM/b+kNAXAC78C+AiAqdCJqDqxlgSOvr3g6NsL732/DqmPgxB9+SSiL51UmyNEa1Oan/PGGQUvaesbwqJJ88rCwNUDlk3cYeHqDrNGLhBpaQmULaUIjEyG3MQYZEdHICs2AtnRlW/z2bGRKnkIF0nmjd3g2mc4XHsPh51nO85Fsqa9/Uef24PC1HiuYRT29g8oWQGw1k2csyjq/+3dd3hVxdbA4d9OAoSE3hGVSFGKiohwlSIKKgrSVBQFARsgKiroJ3IRFBR7xy4KygUBkd5D7713CCSQkJDeT3LK+v44oSlSzp7T530enoSQvfa6XMmsPXtmjeMz4B1v5xJQDINqNzej2s3NaDloNGkx+88UA0m7Nwfs+8p/Y83PPbPo8FwhoWFEVKpKZJWrKFWlOqWqXEVk5epFv7+KyKKvlSxfSc8g+BoR8tNTyDmVQO6pk0UfE8hNdn6ec+okuacSyEtJCqjV96YYBlVvvO3MoF+hVj1loYPt6d9myWX7uNFmw3j06R98rAAo8gXwMlABID8tmdAS4RSPDI7uUZ5QoVY9mvUdQrO+Q8hJPMGRJbM4HD2dExtXBvUPR4fdRk5SPDlJ8SRd5PtCwooRWbmoQKhS7ZwCwfmxVBVn0RBetoLHcg9klsw0cosG8dMD+5kB/lSi8/PkkzhswbXX3BUhoWFc3exO6tzTldptO7ntULJge/rfMe598pJN7/T4SkTSVORzuXyuAPjshpCsHtM2fhe3bul/D8z9g+T9OwAwQkOpVPdGmvYdwvX3P6L7zStSqtrVNOoxgEY9BmDJSufosrms/XK4cyWzdkEOm5Xsk3Fkn4y76PeFFi9xTqFQ/UyREFm5OiVKl6VYRCmKRURQrGSk8/OSkRSLiKRYeETgzTCIYLXkYc3LxZqfizUvp+hjHta8HAqyM51rOc4M7ifPDOz2wgJvZ+/3ylxVk+Yvj+S6uzv8Y5++aoVB9vSfGXeQPZNNH26bjZuO/L0YnysADMNoAcbzcP5/QGK3k7x/B/MGPc76b0by0M/zKF39Wi9lGZjCy5SnfueeZB6PYd0Y/RbGLHthwZmdC1fEMCgWHlFUIESeLRAuVCxc6POSkRSPiCQsIpL8tGSX889PSyZpzxZsebkUnh64Tw/eef/y+TmDuvPzoq9b8oLuVZMvafBQb+p37umRe+UH2dP/hi8GqZh98vjTP/hQHwAAwzC6AhOB8Et9b4Va9Xhs0io9zeoGyfu2M6FrE2+noWmaIj2nb6Fy/Vvcfp9Ci4PcINr3f2z5dJa/9YTZMGlAHRHx+HYTn5lHNwyjNDCWyxj8AdJi9jOzf2fEHlzVpidUrn+LbsWraQGizFU1PTL4Q3A9/dsseWz6+v9UhHrHG4M/+FABgHP73xW9nErYtpat479wUzrBrXbbTt5OQdM0BTz1bznY3v3v/O0Dck+dMBvmIPCdgnRc4jOvAAzDOAZc8WNnWHgEvefuokyNKOU5BbPj65fxZ597XL7+npE/UKZGTRJ3bSJp92aSdm0O6GZEmqZKqao1qHrTbVS98Taq3dSUrPhYoof3czneI+Oiueb2uxVm+E8ikJVmxeHwjfHE3bJOHGZGryY4rIVmQ3USkdkqcnKFLy0CdKlvq82Sx5K3B9D1p3mq8wlqNZq2IrxMeZe7oB3fsJT2n06kZot7z3wtN/kkSbu3OIuCXZtI2r0lII5A1TRXlSxfiao3NqHqTU2pdlNTqt7YhMjK1c/7nnmDXX/HHF6mPDWatjKb5iVZcu1BM/gDbPh8kIrBf4k3B3/wkQLAMIxiXOa7/ws5tmohB+ZO5oYOjynMKriFhIZx3V3t2Tfrfy5dH7NsLrYCC2Elzv7fGlm5OrXufpBadz945mtZ8cfOLwr2bKUwJ8t0/prma4qXKkPVhreeN9hfaubSVmAhZtlcl+953V3tXWrjeyXsNsGSHzzv/uNWziJ+42KzYRzAYAXpmOITBUCRHEwcBLR89KvUbHWf2/e4BpPa93RxuQCw5uUQu2ohte/pfNHvK1MjijI1oqjb7mHnF0RIP3aQxF2bz7w6OLVvW+CecqgFpLDwklSp3/icqfzbKB91/RX3d4hdtRBrXo7LedRue/F/fyrk5QTPqn97QT4bv35dRahfRGSHikBm+EQBICJWwzDmAi4/wuelJrHq4ze4d9SPCjMLblEt7yO0eAmXG7EcXDD1kgXAPxgG5a+7gfLX3UD9Tj0AZw+I1MN7zhYFu7eQdmRf0Pdu13xDsZKRVKhd3zmVXzTYV6zTUMm5EgcXTHX52tDiJYhq1c50DhdTaHFgswbP1P/O3z8iJ/HiDcAuQw7wloJ0TPOlRYAPAdNMBuHR35ZSo+mdapLSmNG/I0eXu7a+onhkafqvSyK0eAnFWTnlJMWTEXuY9GMHST96kPRjB8mIPUxG3BHdFlZTKiSsGOWurU25mnUoH3U95a+7nvJR11OuZh1KVa3hlnvaCwv4/o6qFOZmu3T9da0foMsPcxRndZYIZKYVIg633cKnZMfHMOPJW7FbTXem/K+ImD44QAWfmAEoMgfYD7h+IoUI0SOep+fMbYQWK64ssWBWu01nlwuAwtxsjq1eRO02HRVn5VSqag1KVa3B1c1an/d1sdvJjD9GxrFDpMcechYGRw+SfuwQ2YnHEUeQ/MTSrogREkLpatdQPqou5YoG+PI161Iuqi5la0R5/KTIY6sXuTz4g/un//NzbEEz+ANs+HKwisE/Di+0/P03PlMAiEihYRj9gOWAy43Q02L2s/GH97njxRHKcgtmtdt2ZMnbz7s8aB5aMNVtBcC/MUJDnU9r19YmivvP+zNbgYXM40dIP1pUGMQeIv3YIdKPHiQv9WJHAGmBIqJi1aIn+LqUq1m36Im+LmWvqX3eolVvO2Ri+h/DoJYb/93ZbEKBJXhG/7hVszmxboGKUENExKIikAo+8wrgNMMwfgKeNRMjtFhxes7cpvR4y2D2R/eWnNy+zqVrS5QuS7+1iX4xI1OYk0V67CEyjh0iM/4YecmJ5KYkkpuSdOZzvUPBtxUvVYbIStWIqFyNyEpVz3xetkYU5aLqUr5mXYqXKuPtNC/JXljA982rufzfW/VGt9N98hrFWZ2VlW7FbvOtscNdLOnJzOjdBEu66+dqFFkhIncpSEkZn5kBOMf/AR1xsS8AgN1aSPSI53n0t6WBd6qaF9S5p7PLBUBBdiaxaxZT664OirNSz7lNqwlVG/77OQg2Sz65KYnkpSSSm5x0zudFH1OSznxuN79PWMNZ0EdUqkZk0aB++vOIStWIrFSNyMpVz3weFl7S2+kqEbs22lSx6c7ufwX59qAZ/AHWfPi8isG/AOirIB2lfK4AEJF0wzBeASaZiRO/aSW7//yFG7s9oyiz4FW7bSdWfTLE5esPLZjqFwXA5QgLL0nZq6+j7NXXXfJ7LVnpRTMHSWeKhHMLBktGWtEJe3lY83Ox5ediK/CZ2UG3CCsRTljRiYXFSjpPNwwvV+FvA/rpz6sSUblaUG7tNTX9D1e+++YyORxCfm7w7Pk/OPsXjq9xvQ/DOd4TkYMqAqnkc68ATjMMYz787QXuFQovU55ec3f9o7OWduXGt29IWsx+l64tUaYc/dac9IvXAN4mDgc2S96ZwsB2+kjd/Dysljysec5C4fTnpwuH00WENS+36Hrnn2cnHnf5SOCSFSpTuto1RUcSRxAWHnH2eOKSEWcH8ohIioUX/b7o82Ilnd8bds5AHxYegRHiS8eP+Ca7tZAfmlejIDvTpevLR11PnwX7FGfllJttozBI3v1nx8cws08zbBbT2433Ao1FxOemBH1uBuAczwN7gAhXA1iy0lnwRm8eHrtQvwowqXbbTi4XAAVZGcSuXnReB0DtwoyQEIpFlKJYhMs9sc6zbsw7rB8z0qVrGz3xvF5M6wVxa6JdHvzBfdP/NqsEzeAd5pmiAAAgAElEQVQvDjsrRz2lYvAXoK8vDv7gW6cBnkdEjgGmf/rErV3C5l8+NZ9QkDM7pbh3+nhFmWhaYNs/19TbT7dN/+dlB0/Hv52/fUTyno0qQv0oIu5bjWmSzxYART4HtpkNsubzYSTt2aIgneBV/eb/mHqVErNsDpbMNIUZaVrgKczJ4vDi6S5fX+aqmlx1yx0KM3Ky5NmxB8lRvyn7trBjnJI+PSeBN1QEchefLgBExI5z5aSpVScOm5X5g3vq1rFmGAb1Hnzc5cvt1kIOzPlDYUKaFngOzJti6tyL+p17Kn/d6XAIlrzgWPhns+Sx6t2ncdiVzHYMFBHX3+V4gE8XAAAishn42myc9GMHWTZqoIKMglfDh3qbun7PjN8UZaJpgcnsq7IGXXspyuSsvBw7PrpWXLnN3w4lM07JYv3ZIvKnikDu5PMFQJG3gONmg+z5axwH55vbXhPMKta98aJ75C8ladcmUg/vVZiRpgWO9GMHSdi21uXrr2rcnHLX1lGYEVgLHVgLgmPhX/z6heyf/oOKUDnACyoCuZtfFAAiouwvNHpEf7JPmj7NKWg1MDkLsFfPAmjaBe39y+zTv7l/m38nDsjLDo6pf0tmKqvf76cq3FARMf3A6gl+UQAAiMhswPSUSkFWBvNfexKxB8d/2KrV69Dd1H7+fTMn6L97TfsbcTjYO/N3l68PKxHO9Q90U5iRc8+/wxEcc/9rPxpAfpqSs0CigTEqAnmC3xQARV4AEs0Gid+ymg3fvacgneATXq6iqf38uckniV0brTAjTfN/sWsWk5MU7/L1te/pTInSZZXlU5Bvx1oYHFP/h+b9RtzKWSpCpQG9xVe7612AXxUAInIK6I2zuYIp6797l4StPrs906c1eKiPqev3Th+nJA9NCxRm/0006KJu+t9uC552v5lxB9n45WuqwvUTkQRVwTzBrwoAABFZhILzlMVuZ/5rT5rquBWsolq1I6Kiy2c1cWTJLAqyMhRmpGn+y5KVzuHomS5fH1m5OjWb36MkFxHn1L//PMO6zpqbxdKhj2LNy1YRbpw/rPr/O78rAIoMBbaaDZKVEMuSEf0VpBNcQkLDqN+ph8vX2wosHJg/RWFGmua/DsydjL2wwOXr63fqgREaqiSX/FxbcJz0J8LKUU+TGXtARbSjgF/uMffLAqCor/LjgOnOPgfmTWH7/74xn1SQMdsTYPeUnxVlomn+bc9f40xdr2rvv7XAQUF+cLz33/bLKFWn/NmBniKiZBrB0/yyAAAoOlpRSdW1YvQg4tYtVREqaJjuCbBnCyd3rFeYkab5n7Qj+0jatcnl66veeBsV6zQ0nYfDIeTmBEev/9gVM9kx/gNV4UaLiOvNG7zMbwsAABH5BTA9l+yw25j7ymNkxB1WkFXwMNsTYPsEPfOiBbf4LatNXa/q6T83y44EwcN/xtG9rH7vWRQtctgIuHbUpo/w6wKgSD8g1mwQS2YaM5/vQmFOloKUgkO9Bx831RPg0II/yUtVsvdW0/zSqb2un3UWWqw49Tp0N52DJc+OzRr4o39hdgZL3uyGNT9HRbhcnFP/fj1t4vcFgIhkAD0weWAQOKfj5g1+AnEE/j8GFcLLVjDVE8BuLWTX5J8UZqRp/sVMa+zr7mpPeLmKpu5vswbHlj9xOFj+9pNkx8eoCvmqiBxSFcxb/L4AACg6b3mUilhHV8xn9advqggVFMz2BNj5xw+qTt7SNL9TpkZNl681u/f/9Ja/YLDl+2EkbFTWgGyiiATEk0tAFABF3gXMvVArsnnsJ+ybOUFFqIAX1aodkZWquXx9zqkEDi9y/fxzTfNn1W5u5tJ1JStU5rrWD5i6d162DYc98Lf8xURPYfekz1WF2w08pyqYtwVMASAidpyvApR0mFn8Vl+9Sv0yhISGUa/jE6Zi6G2YWrC69vY2Lu3hv6nbs4SEFXP5voUWB4VBcMpf2qGdrP3weVXhsoCHRSRPVUBvC5gCAEBE4lBUndkLC5j9wsOm+nMHi4YP9zF1ffzmVSTv36EmGU3zIxVq16fpM69f0TWlqlxFs35DXL6nwy7kBcGWP0tmKkuHdsNmUTZe9ynafh4wAqoAAChqx6jkkTI3JZFZA7pis+SrCBewKtZpyLXN25qKoWcBtGB1+0sjqHTDzZf1vWHhJbnv/V8oFlHK5fvlZgV+q1+H3cby4T3ISVR29PvHIhJw7yoDrgAo8gqgpLNP0p4tLBr6tIpQAa1Jn0Gmrt8/eyKWrHRF2Wia/wgtVpzuk1bR6PH+YBj/+n2Rlarx8K+LqNniXpfvlZ9rxxYErX43fvU6iVtXqAq3HAjIleEBWQAU7c3sBhxREe/AvCls+H60ilABK6pVOyrUru/y9TZLvt4SqAWtYhGlaDPiG7qNX0LDh/pQpUFjQosVJ6JiFWo0aUmbEd/w9JIjXNW4ucv3KCxwYMkL/C1/O8aNZv9f36sKlwB0L1pjFnDCvJ2Au4hImmEYnYB1QBmz8dZ+OZxSVWvQsKu6YzcDimFwa+9XiB7ez+UQW8d9QeNeAwkrEa4wMU3zH1c3a83VzVo7fyNy0RmBK2GzSlBs+ds37Tu2jVWyIxzACnQTkYDtVhaQMwCniche4AnA/HJXERYPe47Di2eYDhWo6nfuSckKlV2+Pi81iT3TflWYkab5MUWDv8Mu5GRZIcBn/o8smsSGLwerDPmaP/f5vxwBXQAAiMhcFL2/EbudeYMeJ27tEhXhAk5YiXAaPWFuy83mnz/WjYE0TRERyMm0BXyf/+Nr5rJmdF9VPf4B/hCRr1QF81UBXwAAiMhHwO8qYtmthcx6oSsnt69TES7gNHr8eVNT+FkJseyfPUlhRpoWvHIybdgDvNlP4vZVLB/eU+WDwwYgKFZ+B0UBUOQ5nP/HmmbNz2VG346kHNipIlxAiahYhXqdepiKsemnD1VW8poWlHKzbQF/yE/qgW0sGfII9kKLqpDHgE4iEhR7v4OmABCRAqAroKSzjyUrnWlP36+PEL6AW3u/Yur9ZdqRfRyO1mstNM1Vljw7hZbAHvwzYw+weHBHrLnKTnDNANqLyClVAX1d0BQAACJyEugMKKnu8lKTmNbnPnIST6gIFzAq1mlAVMv7TMXY+P37irLRtOBSWOAI+BP+cpOOs2jQg1gyU1WFtOJs87tPVUB/EFQFAICIbEHh+52shFimPd2O/PQUVSEDQpOnzK3GTdqzhdg1ixVlo2nBwWYV8gJ8u58lI4WFr3Yg95TSB69+IqKkeZw/CboCAEBE/gDeUxUvLWY/fz3zAIU5yqai/N61zdtednvTf6NnATTt8jm3+wV2m19rbhaLBj1I1vFDKsOOFpGg3H8clAVAkbcAZS+aT+3dyoznO+tzA85xa59XTF1/YtMKErauUZSNpgWus9v9Anf0txfkE/3GQ6QdUnpw2B/AMJUB/UnQFgAiIjibBK1SFTN+00rmvNwNh82qKqRfq/fg40RWqmYqxtqvRijKRtMCV25WYG/3c9htLHurB0k7lD4QrMF5wl/g/sVdQtAWAABFWz0eBLaqinl0xXzmvtodu7VQVUi/FVqsOI16vmAqxvH1y4hdvUhRRpoWePKybVgLA3fFv91awPJhT3Bi3XyVYY8AXYp2hwWtoC4AAEQkC7gf2K8q5uHFM5jZryPW/FxVIf1Wo+79CAuPMBVj1adv6r4AmnYBljw7BQG83c+an0P0a12IWz1bZdhTOLf7Bf3K7aAvAABEJBm4F4hVFTN2bTR/PX0/BVkZqkL6pfByFbmp2zOmYiTv286+2RMVZaRpgcEa4Nv9CrLSWfRKe05uXa4ybDpwn4gcVBnUX+kCoIiInMBZBCg7+Slh21qm9m5LflqyqpB+qVn/oRSLKGUqxtovh+vXKppWJNBP98tPS2LBS/eSvHeTyrA5OJ/8la4i9Ge6ADiHiBwC2uHsCKVE8r7tTO7ROqibBUVUrEKTp141FSMr/hg7Jn6nKCNN8182q5CTaQ3Yt2I5ibHMG9CG9Jg9KsNacLb4Xa8yqL/TBcDfFFWHHYA8VTHTjx5g8hN3BnXb4CZPD6Zk+UqmYmz47j3da0ELaoE++GfG7mfegDZkx8eoDGsFHhGRZSqDBgJdAFxA0RnQDwHK5pyzEmKZ8kRrUg7uUhXSrxSPLE2z/kNNxbBkpLLpp48UZaRp/iXQB//UA9uY/8I95CUnqAxrB3oUHQuv/Y0uAP6FiCwEeuD8D0iJ3JREpva8m8QdSg4l9DuNHu9P6erXmoqxdfyX5JxS+gNC03xeoA/+STtWs+Dl+1X29gcQ4FkRmaoyaCDRBcBFiMifQD+VMS1Z6fz51H0c37BcZVi/EFq8BHcMfNtUDJslj/Vj3lGTkKb5gUAf/E+sm8+iwZ1Unup32kARGac6aCDRBcAliMhY4DWVMa15Oczo24GYZXNUhvULDTo/ScU6DU3F2D3tV5L364W8WuAL9MH/6JKpLB36GPYC5S3Uh4rIGNVBA40uAC6DiHwKjFIZ01ZgYfaLD7M/yPa3GyEhtHj1XVMxxG5n6Tsv6uZAmk/JPB7DsVULObToLw7Mm2J6+2+gD/4HZ41l5cg+7mid/p6I6JPELkOYtxPwFyIy3DCMQhQWAg67jfmvP0na0QM0f+ltMAxVoX1a7badqH7LHZzcvs7lGAnb1rJnxm807NpbYWaaduUStq1l89hPiFk6G3Gc7coXEhpGzZb30rjXy9Rsce8VxQz0wX/n7x+z9cfh7gg9XESUPqwFMj0DcAVE5F1gIM7FJcps+PZdZg/sFlStg1sNHm06xqqP38CSla4gG01zze6pY5n8eCuORM88b/AHZ4F/dMV8pj/Xnt1Tx152zEAe/O2FFla9+4y7Bv/BevC/MroAuEIi8jXwNAp3BwAcXjydyU/cSfbJ4yrD+qwaTe8k6s77TcXIT0tm7edBe5Kn5mWHF88g+u3nL/l94nCw+K2+bP/fN5f83kAe/PNSTjL/xXs5slD5a08B+ovIZ6oDBzpdALigaGXpYyjsEwDOroETH/mPqalxf9Jy0GjTrz12Tv6RpD1bFGWkaZcn/egB5r/WA7Ff/nPAms/+S0F25r/+eSAP/sl7NjL72eak7NusOrQd6C0iP6gOHAx0AeAiEZkGdEJhx0CAvNQkpvZqy94Zv6sM65Mq12tEvQ7dTcUQh0MvCNQ8ShwOFg19FluB5YquK8zNZteUny74ZzarI2AH/8Pzf2fBS/eRn5qoOrQV6C4igf/D0k10AWBCUbOgdsC/l/UusBcWsHBIH1Z9MuQf7xUDTfOXRxISVsxUjMSdG9l1Be9YNc2Mbb9/TcK2tS5de2DuH//4mnPwtwXc4C8OOxu/fp3Vo/titxaoDm8BuhT1atFcpAsAk0RkNdAGUH629OafP2bWgC4U5marDu0zyl5Ti5u7m++1tPqzoVgylHYR07R/yIg7whoT607+/gogUAf/wuwMFr/Wmb1T3LIVPxfoICLz3BE8mOgCQAER2QrcCcSrjh2zfC5/PNaCzBNHVYf2Gc1fHklk5eqmYlgyUln58RuKMtK0CxBh8X+fw2Zx/a2fNe/sTh9rYWAO/hnH9jGnb0sSNi1xR/hM4D4RWeqO4MFGFwCKiMg+oBWg9BgrgNTDe5jU7XZObFqhOrRPKFG6LHcP+9J0nD3TfuXoivkKMtK0f9ox6XvT/wZLVa0BgCXfHpCD//HVc5jbrzVZJ464I3wS0KbosDZNAV0AKCQiR4GWgNKDrAHy01OY9lQ7dkz8TnVon1C33cPUuquD6TiL//usfhWgKZeVEMuqT4aYjlOv4xPkZdvIz1G6i9gn7PztQ5YMfRRrnlteWe4F/lM026opogsAxUTkJNAaUL7fxWGzsnTki8x+6WEsmWmqw3tdmxFjKBZRylSM3JRElrzzgqKMNM1p8bDnsOblmIphhIRw9Z2PUGAJrIW9Nksey0f0ZOtPb7trN84yoIWIxLojeDDTBYAbiEgqcBcw3R3xDy+ewYQutxK/aaU7wntN6erX0vzlkabjHJw/9YKrrTXNFbunjiVurfn32Q0eGUDxMlUVZOQ7Mo7tY27/uzi2dJq7bvE7cL+IZLjrBsFMFwBuIiK5wMOAuZNv/kX2yeNM7XMP675++4qakfi6xj1fpGrDJqbjLH3nRXKSlK/J1IJMTuIJVn70uuk4pWvUovFzAXSMtQj7pn3L7Geak35kl7vuMkpEeomI0oZr2lm6AHAjcXoL6A4oP+9S7HbWfzOKqb3akH0yTnV4rzBCQ7ln1A8YoaGm4liy0ln032cVZaUFq+gR/S/ave+yGAYthnxPWHiEmqS8LD81kcWvdWbDF4OxF15ZM6TLZAWeFhG3HBignaULAA8Qkck4dwi45ZE0fstqJnS+lUOL/nJHeI+r0qAxt/Z62XSc2NWL2DHpewUZacFo74zflewqqdelL9VuaaUgI++LWzWbmb1vI37jYnfdIgtoLyK/uusG2lm6APAQEdkCNAU2uiO+JSudOQO7ET28PzaL8skGj7tj4NuUuaqm6TirPvo/MuIOK8hICyYZsYdY/p75IrRUtZo0ed4tbwE9ymbJZe2HA1g69FEsmW7bZXMc52K/aHfdQDufLgA86JwdAv9z1z12TfmJiY80I+XATnfdwiOKlYykzYhLn552Kdb8XOa/3gu7Vb9G1C6PNT+XWS8+Yn7qH2gx5DuKlTS3s8XbkvduYtZT/+HgHLc+lG/Fuc1vtztvop1PFwAeJiIWEekJvAm4ZT9Q6uG9THr0Dnb871t3hPeY61o/wA3tHzUdJ3HHBla8P0hBRlowWDzsOVIPmR+Hru/0DNWb3K0gI+8Qh50d40Yzf0AbdzX2OW08zif/k+68ifZPugDwEhH5AOgKuKVrhq3AwtJRLzFrQBdyU5SfwuUxrYd+Toky5UzH2THxO/bNctvEixYgto7/kgNzJ5uOE1nlapoOGK0gI+/ITjjKvBfasm3sKBx2m7tuUwgMEJE+IuKW1YTaxekCwItEZBbQHHBbo/8jS2czvn1D5zGkfth3NLJSNVq99oGSWNHD+/v9qxHNfeI3r2LVR/+nJFbzN76lWGQZJbE87dC835jVpxnJuze48zbxQGsRCczWpn5CFwBeVvTOqxngtq4+BVkZRA/vz5Sed5F2ZJ+7buM2N3V7lqubtjYdx2bJY/ZLat7taoElN/kkc1/pruRpt277XtRodq+CrDyrIDONZcMeZ837/bDmm+t6eAnLgVtFZL07b6Jdmi4AfICIpAD3AF+58z7xW1YzocutrBvzjn8tijMMHvjkd0pWqGw6VEbcERb8Xy+/nA3R3MNhszLn5ceUvCqLqHwVTQd+pCArDxLh0NzxTO9xM7ErZrj7bp8C94rIKXffSLs0XQD4CBGxisjLQCfAbfts7NZC1o8ZyYTOjYnfvMpdt1GuVNUa3P/heDAM07Fils1hww/vK8hKCwQr3h9MwtY1SmI1f30MxSPLKonlCelHdjFvQBvWfNDfndv7AHKAx0TkNRFx26IC7croAsDHiMhs4GacB2C4TVrMfqY8eTfRw/tRkOUfbbajWrWj2XNvKIm17qsRxK7V242D3f7ZE9n+P/PbTQHqPPAkV9/xgJJY7mbNy2bj168z6+k7OLXb7TPxB3Fu8Zvi7htpV0YXAD5IRBJwvhIYBrivWhZh15SfGd++IQcX/Om226jU/OWR1LjNfFc1cTiYN+gJMuLcur1J82EpB3ay+K1+SmKVr3Ujtw/6Qkksdzu6ZCrTezRi75QxiMPt54hMBZqKyF5330i7croA8FEi4hCR93A2DnLrMZi5KYnMfeUxZvbv5PNnChihobT/9H+ULF/JdCxLRirTn32AvFT9OjLYWDJSmf3SI9gseaZjFY8sy93v/eHzvf4z4w6y8JX2rHi7F3kpbt9ynwM8JSKPikiWu2+muUYXAD5ORNYCt+CspN0qZvlcxne4ia3jv3Tn3l/TSlWtwf0f/aZkPUBG3BFm9OuINT9XQWaaPyjMzeav5zqomf0xDFoO+4kyV9c2H8tN7AX5bP1xBDP7NOXkFre+WTxtPXCLiIzzxM001+kCwA+ISIaIPAr0Bcw/slyENS+HFe8P4rcON/n04UJRrdrR9Dk1e7aTdm9mzsBuPl30aGrYCizMGtCFpF2blMS7uedrXNuyo5JY7nB89Rym92zMzt8/wuH+nT92YCTQSkT0uzU/oAsAPyIiPwG3AW47gPu09GMHmTOwG5Mea078Jre1KDCl+csjqdGkpZJYx1YtJHpYXyWxNN/ksNuY92p3jm9YriRe9SZ30/jZEUpiqZaTGMuSIY+w5M1u5CS69Q3iaUeBO0VkhF7l7z90AeBnRGQfzsZBapYuX0Lijg1MefJuZvTvSMpBt9cdVyQkNIz2n01Ush4AYM/08az5fJiSWJqPEWHR0Gc4snS2knCRVa6m9du/YYSEKomnijU/hx3jRjO9Z2OOr5nrqdv+jnPKf62nbqipoQsAP1R0oNCLQBcgzRP3PLp8HhO63MrCIU/51EJBlf0BADb+8D47JurupIFm2XuvsG/mBCWxQooV565REwkvp6bwVMFekM/uSV8wrVs9to0dhb3AI0eCZwCPi0gvvdDPP+kCwI+JyEygAWD+9JLLuZ/Dwd4Zv/Fru3qs/PB1LJkeqT0uKerO+5WtBwBY9u5ADi+eriye5l3rvn6b7RPGKIvXbODHVG7QVFk8MxzWQvZN+44/H2vA5m/fdHczn3MtBxqJyB+euqGmni4A/JyIJIlId6ADbt4ueJq9sIAtv37GL/fWZdNPH2GzeORp46JUrgcQh4O5rz7u04sgtcuzdfyXrP9mlLJ4te/vQb0u3l8r4rDbODj7F6Y9fiMbvhhEfqrHTvzMBPoBbUTEd6YCNZfoAiBAiMg8oCHwOc7VuG5XkJXB6k/f5Nd2N7D7z18Qu0due0EhoWE8+NUUyl5TS0k8h83KvFcf58Bc/YDjr/ZMH8+KDwYri1ehzs00f+1rZfFcIQ4HRxZOZHqPRqz96AVyk4578vZ/AfVF5EcRfZhGINAFQAARkVwRGQT8B9jmqfvmJMWzeNhz/N75Fo4smeWp2/5DRMWqPDR2AREVqyiJ57DbmP/6k+yd8ZuSeJrnHF48ncXDnlN26FPxUmW5+91JhJYoqSTeFRPh2LK/mNGrCavefYbs+BhP3j0BeEhEHhYRt3cQ0jxHFwABSES2AE2B13Bz34BzpR7ey6wXuvJH95YciZ6JOByeuvUZ5a6tTZcf51A8srSSeOJwsPDNp9k15Wcl8TT32z11LHNf6a5sRiq0REnafjCN0jXUzC5dqeOr5zDr6dtZPrwHmbH7PXlrAX4EGoiIXhQTgHQBEKBExC4in+J8LbDAk/c+uX0ds158iHH312fH/771eJe9qg2b0PHraYQWK64moAjRI/orOzRGc5+1Xw5n8Vt9lTV1CgkN466RE6jaqIWSeFciYWM0c/q2Ysmb3Ug7vNPTtz8A3CUi/UQk09M31zxDFwABTkSOicgDwBOAR5veZ8QdZumol/i5dU1WfzaUnFMJHrv3tc3b0u6DX5VtD0SEZaMGsuXXz9XE05Ry2KwseKM3G757T11Qw6DFmz9wTfP26mJegsNmJWbxZOb0bcWiwR1J2bfZY/cuYgXew7nC3zc7gGnK6AIgSIjIJKAeMBbn1J7HWLLS2fTjh4xtU4sFb/Qmed92j9z3hg7daT3kU6UxV374Gmu/eEvZu2XNvMKcLKY/117ZPv/Tmr34EbXbPaE05r/JTzvFjnGjmfpwXVaO7OONgR9gJdBERIaJSIE3EtA8SxcAQURE0kXkWeBuYJ+n7++wWdk3cwITujbhz95tiVk+1+0D6a29X+a2Z19XGnPD96OZ9dLDWPNylMbVrlxO4gkmP3EnceuWKo17c683aPDoi0pjXkjK/q2sevcZpj5Sl21jR5GfluT2e17AUeAREWktIr7V7lNzK10ABCERWQHchHM/r1dW9R7fsJyZ/Tsxrn1Ddk7+0a29BFoNfp8GXXopjXkkeiaTHmtB5omjSuNqly/lwE4mPdZceYvqGzo/y63Pva005rkcNitHl0xl7vN3Mee5FhxZONETB/VcSDYwBOfWvmneSEDzLl0ABKmiRYI/AnWB4Th/GHhc+tEDLBnxPD/fHcXar0aQl+qGJyDD4N73fiLqzvuVhk09tJuJj/yHExtXKI2rXVrc2iVM7tGanKR4pXGj2jzM7YO+VBrzNEtGCjvGf8Cf3W5gxdu9SN69wS33uQwO4Cegroh8qKf7g5cuAIJcUe+AUUAd4FvAKyd55aensOHbd/n57utYNPQZTm5fpzR+SGgYHb+aSrVG/1Ea15KRyrSn7tPnB3jQ7qljmd63A4U5atvPX9W0LXcO+wUjRO2PxbRDO1g9ui9TH6rDtp/fIS/Fq1vplwG3ikhfEfHK+wbNd+gCQANARE6JyAs4zxbw2nSgvbCAPX+N44/uLfn1vutZ9/XbZMQeUhI7LDyCrj/Mpvx1NyiJd5rDbmPpyBdZMuJ5HDar0tjaWZaMVOa8/Khzm5/iv+fKDZrSZvRkQhRtHbVZ8oiJnsL8F9oy6+nbOTz/d+xWrz5oHwa6ikgbEdnhzUQ036ELAO08InJIRB4B7gBWezOXjLgjrP9mFL+2q8ekR+9g+4Qx5Kclm4oZXq4i3X5bQuV6jRRledbOyT/yx2MtSDvi8fWVAe/oyoWMf7ARhxaqr03LRdXnno9nEhYeaSqOw2blxLr5rBz1FJM71WTlO71J2un1E3JTcTYEaygiM7ydjOZbDN3SWbsYwzA6Ax/g3ELodSGhYdRseS/1O/WkdttOhIVHuBSnIDuTWQO6cmKT+vf3YSXCaTFoNLf2GqiuD4GL1o15h/VjRrp07e0vDueOF0cozujKWPPzWP7+6+ye8r1b4ldu0JS2H00nvGxF161uzwQAAAhWSURBVAKIkLhjNUejp3Bs+V8U+MgJmUA68CnwlYh4ZX2P5vvCvJ2A5ttEZKZhGHOAZ4C3gerezMdht3F0xXyOrphPsYhS1L2vK/U69eTa29tc0bvbEqXL8tDY+cwb3EP50b+2Agsr3h9EzNJZtPvgV0pXv1Zp/GAgAnGb1hP93z5kHVfzCujvrr7jAe4aOcGlIjL14HZiFv/BsSV/kpusdiGiSZnAF8DnuoOfdil6BkC7bIZhRAKDgMFAWS+nc57IytWp92B36nXsQZUGjS/7OnE4WPrOC+yc/KNb8ipeqgx3D/tS+TbEy+VvMwAikJddwMbv32Pn+A+VtfT9u7odenPH62MICb38Z6Cs44eIiZ5CzOLJbitKTMgGvgI+FZF0byej+QddAGhXzDCMMjh7CLwCXOXldP6hYp0G1Ov4BLXu6kClG26+rGvMDJSXo869XWj79nfKTiq8XP5SAIgDLPl2kg/uZ8XIp0jZt8Vt92rUewiNn728/125yfEcW/InMYv/IPWgZzpYXqFcYAzwsYikejsZzb/oAkBzmWEYxYGewOv4yBqBv4usXJ2olvdRs2U7ara4h/By//6ud+cfP7B05ItuO8WweKkyNO37Brf2foWwEuFuucff+XoBcHrgzz6Vyo7fP2bfn99iL7S45V5GSAj/efVz6nXp+6/f47DbSN6zkYRN0cRvWEzK/i2+2vY5H/gO+FBEPHrGhxY4dAGgmWYYhgF0Av4PaO7ldP6VERJClYZNiGrVjqiW91Gt0X/+MQV8aNFfzH+tJ/ZC923ZKl39Glq8+h71Oz7h9kWCvloAOBxCQb6D3PRs9kz5ht0TP6Uwx32vrEOLh9N6xHiuvbPTP/4sO+EoCRujid+4mJNbV2DNVdtfQLF04Huci/sSvZ2M5t90AaApZRhGC5yFQEfAu0vgL6FE6bJcc3sbolrdT1Sr+84s1juxcQUzB3RR3mjm76o2bMKdQz7m6qat3XYPXysAHA6hIM9Bfo6FA7N/Zcevo93e/7546XK0/WAaVW921qbWvGwSt64gfmM0CZuiyTpxxK33V+QwzsV940TEs+drawFLFwCaWxiGUR/nq4EegJruKm5WoVY9ara8j6iW7ShRpiyzX3yE3BT3P2TVbtORloPfp0Lt+spj+0oB4HAIljwHhfk2jkRPZdvP75AdH6Mk9sVEVrmaez6ejr2wkISNi4nfGE3yng3+1LBpNfAZMFNE3PNuSgtaehug5hYisg942jCMt3AuFuwLlPFuVheXFrOftJj9bPvtK0KLl6B0tWs8ct8jS2dzZNkcolreR+MnBxLVqp3X+weoYrMKBfl2CgsdxK9byJYfh5N2aKfH7l+q2rUsGNjOl/bnXw478CfwmYhs9HYyWuDSBYDmViISD7xuGMa7QH9gID64c+Dv7IUFZMQd9twNRTi2aiHHVi2kXM263NLzBRo+1IfikaU9l4Mi4hAKLA4KLQ6ykxKIWTyZmEWTSDvsuYH/NB/oxHclsoCfcb7fj/V2Mlrg0wWA5hFFTUk+NAzjE+ABnI2FOgDFvJqYD8qIPcTy915h7Rdv0aBrb27p+QLlo673dlqXZC10Dvq56ZnErphJzKJJnNy63G27KgLIDmAsMF5EfHoFohZYdAGgeZSI2IE5wBzDMKoAvYCnAfUvwP1cYW422yeMYfuEMVSu14habTpSu01HqjZs4jOvCBwOodDiID+3kBPrFhOzaBJxq+dgs+R5OzVflwVMAn4Wkc3eTkYLTroA0LymaP/yJ8AnhmHcjnNW4DHA/+a93Sx5/w6S9+9gw7fvUqrKVdS6+0FqtenEtXe0IbR4CY/nYy10kHYsjpM7N5G4bSVHl07Fkm7uoKYgsRrnNP9UEdFVkuZVugDQfIKIrAfWG4bxCtAN56xAK+9m5ZtyTiWwc/KP7Jz8I8VKRlK98e1UvuFmKt1wM5Wuv4mKdRooLwryUk+RuHMz8ds3krRrMyn7t5CfpvvPXKYk4DdgrIgc8HYymnaa3gao+SzDMOriLAR64+VDiPxJSGgY5a+7gUo33ETOqQTiN610KU6N21oRUaEyibs2k30yTnGWAc8KLML5bn+OiPjNvkMteOgCQPN5hmGE4lw4+DTOhYN+0VdACzo2YAkwFZguIn6191ALProA0PxK0UFE9wOdgfZAOe9mpAU5G7AUmIIe9DU/owsAzW8ZhlEMaI2zGOgMeKZzjxbsTg/6p5/09Sl8ml/SBYAWMAzDaAx0wVkMNPJyOlpgKQCWA9OAv/SgrwUCXQBoAckwjJqcnRm4E73jRbtyh4H5wAJgud62pwUaXQBoAc8wjPI4Fw92Bu4Fyno3I81H5QLLcA74C0TEL44J1DRX6QJACyqGYYQAN+GcFWhV9KuaV5PSvGkPzgF/PrBaRAq8nI+meYwuALSgZxhGHZyFwOmioLZ3M9LcxAZsB9YAa3EO+AneTUnTvEcXAJr2N4ZhVOfs7EArnDMGIV5NSnNFOrAO52C/Btio3+Nr2lm6ANC0SzAMoxzQAmcx0BxnQaD7D/gWB85Fe2s5O+DvE/0DTtP+lS4ANM0FhmHUAG78268GQIQ38woSqcAuYOc5H/eISK5Xs9I0P6MLAE1TxDAMA6gFNOT8wuAGdPtiVxQC+zh/oN+l39trmhq6ANA0NzMMIwy4nrMFQW2gBnBV0cdgnTVwAAnAsX/5FSsiNm8kpmnBQBcAmuZlRWsMThcDNf72+enfVwVCvZWjC3KAlKJfyUW/4jh/gD8uIoXeSU/TNF0AaJofKDoRsRpni4OyOGcOShZ9vNxf537/6Z0NAlhwtru90McLfS2LswP86UH+zO9FxOKOvwdN09T5fw8/5WzcYiSaAAAAAElFTkSuQmCC"
# Base64 encoded favicon image
# Destination directory for the favicon file
STATIC_DIR="$APP_DIR/static"
# Destination path for the favicon file
FAVICON_PATH="$STATIC_DIR/favicon.png"

# Create static directory if it doesn't exist
mkdir -p "$STATIC_DIR" || error_exit "Failed to create static directory."

# Decode the base64 encoded PNG favicon and save it to the file
echo "$FAVICON_BASE64" | base64 -d > "$FAVICON_PATH" || error_exit "Failed to decode and save favicon."

# Ensure the favicon file is accessible
chmod 644 "$FAVICON_PATH" || error_exit "Failed to set permissions for favicon."

echo "Favicon saved successfully."

# Create the templates directory and the HTML templates
echo "Creating HTML templates..."
mkdir -p $APP_DIR/templates
tee $APP_DIR/templates/layout.html > /dev/null <<EOL
<!doctype html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>DNS Management</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
    <link href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.5.2/css/all.min.css" rel="stylesheet">
</head>
<body>
    <nav class="navbar navbar-expand-lg navbar-light bg-light">
        <div class="container">
            <a class="navbar-brand" href="{{ url_for('index') }}">DNS Management</a>
            <div class="collapse navbar-collapse">
                <ul class="navbar-nav ms-auto">
                    {% if 'username' in session %}
                    <li class="nav-item">
                        <form action="{{ url_for('logout') }}" method="post" class="d-inline">
                            <button type="submit" class="btn btn-outline-secondary">Logout</button>
                        </form>
                    </li>
                    {% endif %}
                </ul>
            </div>
        </div>
    </nav>
    <div class="container">
        {% with messages = get_flashed_messages() %}
        {% if messages %}
        <div class="alert alert-info" role="alert">
            {{ messages[0] }}
        </div>
        {% endif %}
        {% endwith %}
        {% block content %}{% endblock %}
    </div>
</body>
</html>
EOL

tee $APP_DIR/templates/change_credentials.html > /dev/null <<EOL
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-6">
        <h2>Change Credentials</h2>
        <form method="post">
            <div class="form-group">
                <label for="username">New Username</label>
                <input type="text" class="form-control" id="username" name="username" required>
            </div>
            <div class="form-group">
                <label for="password">New Password</label>
                <input type="password" class="form-control" id="password" name="password" required>
            </div>
            <button type="submit" class="btn btn-primary mt-3">Change Credentials</button>
            <a href="{{ url_for('index') }}" class="btn btn-secondary mt-3">Cancel</a>
        </form>
    </div>
</div>
{% endblock %}
EOL

tee $APP_DIR/templates/index.html > /dev/null <<EOL
{% extends "layout.html" %}
{% block content %}
<div class="d-flex justify-content-between my-3">
    <a href="{{ url_for('add') }}" class="btn btn-primary"><i class="fa fa-plus"></i> Add New Domain</a>
    <a href="{{ url_for('change_credentials') }}" class="btn btn-info mx-3"><i class="fa fa-key"></i> Change Credentials</a>
</div>
<div class="table-responsive">
    <table class="table table-striped table-bordered">
        <thead class="table-dark">
            <tr>
                <th>Domain Name</th>
                <th>IP Address</th>
                <th>Actions</th>
            </tr>
        </thead>
        <tbody>
            {% if entries %}
                {% for entry in entries %}
                <tr>
                    <td>{{ entry[0] }}</td>
                    <td>{{ entry[1] }}</td>
                    <td>
                        <a href="{{ url_for('edit', name=entry[0]) }}" class="btn btn-warning btn-sm mx-3"><i class="fa fa-edit"></i> Edit</a>
                        <a href="{{ url_for('delete', name=entry[0]) }}" class="btn btn-danger btn-sm"><i class="fa fa-trash"></i> Delete</a>
                    </td>
                </tr>
                {% endfor %}
            {% else %}
                <tr>
                    <td colspan="3">No entries found.</td>
                </tr>
            {% endif %}
        </tbody>
    </table>
</div>
{% endblock %}
EOL

tee $APP_DIR/templates/login.html > /dev/null <<EOL
<!doctype html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Login</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css" rel="stylesheet" integrity="sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH" crossorigin="anonymous">
</head>
<body>
    <div class="container">
        <div class="row justify-content-center">
            <div class="col-md-6">
                <h2 class="mt-5">Login</h2>
                {% if error %}
                <div class="alert alert-danger">{{ error }}</div>
                {% endif %}
                <form method="post">
                    <div class="form-group">
                        <label for="username">Username</label>
                        <input type="text" class="form-control" id="username" name="username" required>
                    </div>
                    <div class="form-group">
                        <label for="password">Password</label>
                        <input type="password" class="form-control" id="password" name="password" required>
                    </div>
                    <button type="submit" class="btn btn-primary mt-3">Login</button>
                </form>
            </div>
        </div>
    </div>
</body>
</html>
EOL

tee $APP_DIR/templates/add.html > /dev/null <<EOL
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-6">
        <h2>Add New Domain</h2>
        <form method="post">
            <div class="form-group">
                <label for="name">Domain Name</label>
                <input type="text" class="form-control" id="name" name="name" required>
            </div>
            <div class="form-group">
                <label for="ip">IP Address</label>
                <input type="text" class="form-control" id="ip" name="ip" required>
            </div>
            <button type="submit" class="btn btn-primary mt-3">Add Domain</button>
            <a href="{{ url_for('index') }}" class="btn btn-secondary mt-3">Cancel</a>
        </form>
    </div>
</div>
{% endblock %}
EOL

tee $APP_DIR/templates/edit.html > /dev/null <<EOL
{% extends "layout.html" %}
{% block content %}
<div class="row justify-content-center">
    <div class="col-md-6">
        <h2>Edit Entry</h2>
        <form method="post">
            <div class="form-group">
                <label for="name">Domain Name</label>
                <input type="text" class="form-control" id="name" name="name" value="{{ entry[0] }}" required>
            </div>
            <div class="form-group">
                <label for="ip">IP Address</label>
                <input type="text" class="form-control" id="ip" name="ip" value="{{ entry[1] }}" required>
            </div>
            <button type="submit" class="btn btn-primary mt-3">Save</button>
            <a href="{{ url_for('index') }}" class="btn btn-secondary mt-3">Cancel</a>
        </form>
    </div>
</div>
{% endblock %}
EOL

tee $APP_DIR/templates/error.html > /dev/null <<EOL
{% extends "layout.html" %}
{% block content %}
<div class="alert alert-danger">
    <strong>Error:</strong> {{ error }}
</div>
<a href="{{ url_for('index') }}" class="btn btn-secondary mt-3">Back</a>
{% endblock %}
EOL

# Create a systemd service for the Flask app
echo "Creating systemd service for the Flask app..."
sudo tee /etc/systemd/system/dns-web-interface.service > /dev/null <<EOL
[Unit]
Description=DNS Web Interface
After=network.target

[Service]
User=pi
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/../dns-web-interface-venv/bin/python $APP_DIR/app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOL

# Enable and start the Flask app service
echo "Enabling and starting the Flask app service..."
sudo systemctl enable dns-web-interface

# Check if dns-web-interface service is active
if sudo systemctl is-active --quiet dns-web-interface; then
    # If active, restart the service
    echo "Restarting dns-web-interface service..."
    sudo systemctl restart dns-web-interface
else
    # If not active, start the service
    echo "Starting dns-web-interface service..."
    sudo systemctl start dns-web-interface
fi

# Restart dnsmasq to apply changes
echo "Restarting dnsmasq..."
sudo systemctl restart dnsmasq || error_exit "Failed to restart dnsmasq."

# Install dnsutils package for dig command
echo "Installing dnsutils package..."
sudo apt install -y dnsutils || error_exit "Failed to install dnsutils."

# Verify DNS configuration
echo "Verifying DNS configuration..."
dig +short ${RPI_HOSTNAME}.local || error_exit "DNS configuration verification failed for ${RPI_HOSTNAME}.local."

echo "DNS server setup is complete. Your Raspberry Pi is now an authoritative DNS server for the specified domains."
echo "Logs are being written to RAM to minimize wear on the microSD card."
echo "Web interface is available at http://${RPI_IP}:5000"
