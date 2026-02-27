#!/bin/bash
# =============================================================================
# OMNIPANEL V1.0 - Simple Edition
# Limited Resources: Images (6), Containers (10), Compose (5)
# Support: Debian & Ubuntu Only
# =============================================================================

set -e

# Configuration
INSTALL_DIR="/opt/omnipanel"
VENV_DIR="$INSTALL_DIR/venv"
STACKS_DIR="$INSTALL_DIR/stacks"
DNS_DIR="$INSTALL_DIR/dns"
CONFIG_DIR="$INSTALL_DIR/config"
LOGS_DIR="$INSTALL_DIR/logs"
LIMITS_FILE="$CONFIG_DIR/limits.conf"

# Service Configuration
PANEL_USER="omnipanel"
SSH_PORT="4086"
DNS_PORT="5353"
DNS_DOMAIN="lan"

# Limits
MAX_IMAGES=6
MAX_CONTAINERS=10
MAX_COMPOSE=5

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
WHITE='\033[1;37m'
NC='\033[0m'

# =============================================================================
# Logging Functions
# =============================================================================
log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step() { echo -e "${CYAN}[STEP]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }

# =============================================================================
# Detect OS (Debian/Ubuntu only)
# =============================================================================
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID=$ID
        OS_NAME=$NAME
        
        case $OS_ID in
            ubuntu|debian)
                log_info "Detected OS: $OS_NAME - Supported"
                ;;
            *)
                log_error "Unsupported OS: $OS_NAME"
                log_error "This installer only supports Debian and Ubuntu"
                exit 1
                ;;
        esac
    else
        log_error "Cannot detect OS"
        exit 1
    fi
}

# =============================================================================
# Get Server IP
# =============================================================================
get_server_ip() {
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1 || echo "127.0.0.1"
}

# =============================================================================
# Install Dependencies
# =============================================================================
install_dependencies() {
    log_step "Installing dependencies..."
    
    apt-get update
    apt-get install -y python3 python3-pip python3-venv dnsmasq jq curl apt-transport-https ca-certificates gnupg lsb-release
    
    log_success "Dependencies installed"
}

# =============================================================================
# Install Docker
# =============================================================================
install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log_info "Docker already installed: $(docker --version)"
        return
    fi

    log_step "Installing Docker..."
    
    # Remove old versions
    apt-get remove -y docker docker-engine docker.io containerd runc 2>/dev/null || true
    
    # Add Docker's GPG key
    install -m 0755 -d /etc/apt/keyrings
    
    if [ "$OS_ID" = "ubuntu" ]; then
        curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    else
        # Debian
        curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
        echo \
          "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
          $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null
    fi
    
    chmod a+r /etc/apt/keyrings/docker.gpg
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    
    systemctl enable docker
    systemctl start docker
    
    log_success "Docker installed: $(docker --version)"
}

# =============================================================================
# Setup Docker Group
# =============================================================================
setup_docker_group() {
    if ! getent group docker >/dev/null; then
        log_step "Creating docker group..."
        groupadd docker
        log_success "Docker group created"
    fi
}

# =============================================================================
# Setup Limits File
# =============================================================================
setup_limits() {
    cat > "$LIMITS_FILE" << EOF
# OmniPanel Limits
MAX_IMAGES=$MAX_IMAGES
MAX_CONTAINERS=$MAX_CONTAINERS
MAX_COMPOSE=$MAX_COMPOSE
EOF
    chmod 644 "$LIMITS_FILE"
    log_success "Limits configured: Images=$MAX_IMAGES, Containers=$MAX_CONTAINERS, Compose=$MAX_COMPOSE"
}

# =============================================================================
# Setup Password
# =============================================================================
setup_password() {
    echo -e "\n${CYAN}=== PASSWORD SETUP ===${NC}"
    echo "Please enter password for user $PANEL_USER"
    echo ""
    
    while true; do
        read -sp "Enter password: " PANEL_PASSWORD
        echo ""
        read -sp "Confirm password: " PASS_CONFIRM
        echo ""
        
        if [ "$PANEL_PASSWORD" != "$PASS_CONFIRM" ]; then
            echo -e "${RED}Passwords do not match!${NC}"
            continue
        fi
        
        if [ ${#PANEL_PASSWORD} -lt 6 ]; then
            echo -e "${RED}Password must be at least 6 characters!${NC}"
            continue
        fi
        
        break
    done
    
    log_success "Password set"
}

# =============================================================================
# Setup User
# =============================================================================
setup_user() {
    log_step "Creating panel user..."
    
    setup_docker_group
    setup_password
    
    if ! id -u "$PANEL_USER" >/dev/null 2>&1; then
        useradd -m -s /bin/bash -G docker "$PANEL_USER"
        echo "$PANEL_USER:$PANEL_PASSWORD" | chpasswd
    else
        echo "$PANEL_USER:$PANEL_PASSWORD" | chpasswd
        usermod -a -G docker "$PANEL_USER"
    fi
    
    mkdir -p "$INSTALL_DIR"
    echo "$PANEL_PASSWORD" > "$INSTALL_DIR/.password"
    chmod 600 "$INSTALL_DIR/.password"
    
    echo "$PANEL_USER ALL=(ALL) NOPASSWD: /usr/bin/docker *" > /etc/sudoers.d/omnipanel
    chmod 440 /etc/sudoers.d/omnipanel
    
    log_success "User created"
}

# =============================================================================
# Setup Directories
# =============================================================================
setup_directories() {
    log_step "Creating directories..."
    
    mkdir -p "$VENV_DIR" "$STACKS_DIR" "$DNS_DIR" "$CONFIG_DIR" "$LOGS_DIR"
    chown -R "$PANEL_USER:$PANEL_USER" "$INSTALL_DIR"
    
    log_success "Directories created"
}

# =============================================================================
# Setup SSH
# =============================================================================
setup_ssh() {
    log_step "Configuring SSH..."
    
    cp /etc/ssh/sshd_config /etc/ssh/sshd_config.backup
    
    if ! grep -q "^Port $SSH_PORT" /etc/ssh/sshd_config; then
        echo "Port $SSH_PORT" >> /etc/ssh/sshd_config
    fi
    
    cat > "$INSTALL_DIR/ssh-wrapper.sh" << 'EOF'
#!/bin/bash
export OMNIPANEL_HOME="/opt/omnipanel"
export PATH="$OMNIPANEL_HOME/venv/bin:$PATH"

clear
echo "╔════════════════════════════════════════════════════════════╗"
echo "║         OMNIPANEL V1.0 - SIMPLE EDITION                   ║"
echo "║     Limited: 6 Images | 10 Containers | 5 Compose Stacks  ║"
echo "║     Type 'help' for commands                              ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""

python3 "$OMNIPANEL_HOME/panel.py"
EOF
    chmod 755 "$INSTALL_DIR/ssh-wrapper.sh"
    
    sed -i '/^Match User omnipanel/,/^$/d' /etc/ssh/sshd_config
    
    cat >> /etc/ssh/sshd_config << EOF

Match User $PANEL_USER
    ForceCommand $INSTALL_DIR/ssh-wrapper.sh
    X11Forwarding no
    PermitTTY yes
    PasswordAuthentication yes
    MaxSessions 1
EOF

    if sshd -t 2>/dev/null; then
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        log_success "SSH configured on port $SSH_PORT"
    else
        log_error "SSH config error - restoring backup"
        cp /etc/ssh/sshd_config.backup /etc/ssh/sshd_config
        systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
        exit 1
    fi
}

# =============================================================================
# Setup Python Virtual Environment
# =============================================================================
setup_venv() {
    log_step "Creating Python environment..."
    
    sudo -u "$PANEL_USER" python3 -m venv "$VENV_DIR"
    sudo -u "$PANEL_USER" "$VENV_DIR/bin/pip" install pyyaml
    
    log_success "Python environment created"
}

# =============================================================================
# Setup DNS
# =============================================================================
setup_dns() {
    log_step "Configuring DNS..."
    
    SERVER_IP=$(get_server_ip)
    
    cat > "$CONFIG_DIR/dnsmasq.conf" << EOF
port=$DNS_PORT
bind-interfaces
listen-address=127.0.0.1
domain=$DNS_DOMAIN
local=/$DNS_DOMAIN/
addn-hosts=$DNS_DIR/hosts
cache-size=1000
server=8.8.8.8
server=8.8.4.4
EOF

    echo "$SERVER_IP panel.$DNS_DOMAIN" > "$DNS_DIR/hosts"
    echo "127.0.0.1 localhost" >> "$DNS_DIR/hosts"
    
    cat > "$INSTALL_DIR/update-dns.sh" << 'EOF'
#!/bin/bash
DNS_DIR="/opt/omnipanel/dns"
DNS_DOMAIN="lan"
SERVER_IP=$(ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1)
TEMP_HOSTS=$(mktemp)

echo "$SERVER_IP panel.$DNS_DOMAIN" > "$TEMP_HOSTS"
echo "127.0.0.1 localhost" >> "$TEMP_HOSTS"

docker ps --format '{{.Names}}' 2>/dev/null | while read container; do
    [ -n "$container" ] && echo "$SERVER_IP $container.$DNS_DOMAIN" >> "$TEMP_HOSTS"
done

if ! cmp -s "$TEMP_HOSTS" "$DNS_DIR/hosts"; then
    mv "$TEMP_HOSTS" "$DNS_DIR/hosts"
    systemctl reload omnipanel-dns 2>/dev/null || systemctl restart omnipanel-dns
else
    rm -f "$TEMP_HOSTS"
fi
EOF
    chmod 755 "$INSTALL_DIR/update-dns.sh"
    
    cat > /etc/systemd/system/omnipanel-dns.service << EOF
[Unit]
Description=OmniPanel DNS
After=network.target docker.service

[Service]
Type=simple
User=$PANEL_USER
ExecStart=/usr/sbin/dnsmasq -k -C $CONFIG_DIR/dnsmasq.conf
Restart=always

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/omnipanel-dns-update.service << EOF
[Unit]
Description=DNS Update
After=docker.service

[Service]
Type=oneshot
User=$PANEL_USER
ExecStart=$INSTALL_DIR/update-dns.sh
EOF

    cat > /etc/systemd/system/omnipanel-dns-update.timer << EOF
[Unit]
Description=DNS Update Timer

[Timer]
OnCalendar=*:0/1

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable omnipanel-dns omnipanel-dns-update.timer
    systemctl start omnipanel-dns omnipanel-dns-update.timer
    
    log_success "DNS configured with server IP: $SERVER_IP"
}

# =============================================================================
# Create Panel Python Script with Limits
# =============================================================================
create_panel() {
    log_step "Creating panel interface with resource limits..."
    
    cat > "$INSTALL_DIR/panel.py" << 'EOF'
#!/usr/bin/env python3
# =============================================================================
# OMNIPANEL V1.0 - Simple Edition with Limits
# Max: 6 Images, 10 Containers, 5 Compose Stacks
# =============================================================================

import os
import sys
import subprocess
from pathlib import Path

# Colors
class Colors:
    RED = '\033[0;31m'
    GREEN = '\033[0;32m'
    YELLOW = '\033[1;33m'
    BLUE = '\033[0;34m'
    CYAN = '\033[0;36m'
    NC = '\033[0m'
    BOLD = '\033[1m'

# Limits
MAX_IMAGES = 6
MAX_CONTAINERS = 10
MAX_COMPOSE = 5

class OmniPanel:
    def __init__(self):
        self.user = os.getenv('USER', 'unknown')
        self.stacks_dir = Path("/opt/omnipanel/stacks")
        self.dns_dir = Path("/opt/omnipanel/dns")
        self.dns_domain = "lan"
        self.server_ip = self.get_server_ip()
        
    def get_server_ip(self):
        try:
            ip = subprocess.check_output(
                "ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1' | head -1",
                shell=True, text=True
            ).strip()
            return ip if ip else "127.0.0.1"
        except:
            return "127.0.0.1"
    
    def count_images(self):
        result = subprocess.run("docker images -q | wc -l", shell=True, capture_output=True, text=True)
        return int(result.stdout.strip() or 0)
    
    def count_containers(self, all_c=False):
        cmd = "docker ps -aq | wc -l" if all_c else "docker ps -q | wc -l"
        result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
        return int(result.stdout.strip() or 0)
    
    def count_stacks(self):
        count = 0
        if self.stacks_dir.exists():
            for stack in self.stacks_dir.iterdir():
                if stack.is_dir() and (stack/'docker-compose.yml').exists():
                    count += 1
        return count
    
    def print_help(self):
        print(f"""
{Colors.CYAN}COMMANDS (LIMITED EDITION):{Colors.NC}
{Colors.YELLOW}Max Images: {MAX_IMAGES} | Max Containers: {MAX_CONTAINERS} | Max Stacks: {MAX_COMPOSE}{Colors.NC}

{Colors.BOLD}SYSTEM:{Colors.NC}
  help                 - Show this help
  clear                - Clear screen
  exit                 - Exit panel
  version              - Show versions
  limits               - Show current usage

{Colors.BOLD}IMAGES ({self.count_images()}/{MAX_IMAGES}):{Colors.NC}
  image ls             - List images
  image pull <name>    - Pull image
  image rm <id>        - Remove image

{Colors.BOLD}CONTAINERS ({self.count_containers()}/{MAX_CONTAINERS}):{Colors.NC}
  container ls         - List running containers
  container ls -a      - List all containers
  container run <image> - Run container (auto-pull)
  container stop <id>  - Stop container
  container start <id> - Start container
  container restart <id> - Restart container
  container rm <id>    - Remove container
  container logs <id>  - Show logs

{Colors.BOLD}VOLUMES:{Colors.NC}
  volume ls            - List volumes

{Colors.BOLD}COMPOSE ({self.count_stacks()}/{MAX_COMPOSE}):{Colors.NC}
  compose ls           - List stacks
  compose create       - Create new stack
  compose start <name> - Start stack
  compose stop <name>  - Stop stack
  compose logs <name>  - Show logs

{Colors.BOLD}DNS (.{self.dns_domain}):{Colors.NC}
  dns ls               - List DNS entries
""")
    
    def check_limit(self, current, max_limit, resource):
        if current >= max_limit:
            print(f"{Colors.RED}Limit reached! Maximum {max_limit} {resource} allowed.{Colors.NC}")
            return False
        return True
    
    def run_cmd(self, cmd):
        try:
            subprocess.run(cmd, shell=True)
        except Exception as e:
            print(f"{Colors.RED}Error: {e}{Colors.NC}")
    
    def run_cmd_capture(self, cmd):
        try:
            result = subprocess.run(cmd, shell=True, capture_output=True, text=True)
            return result.stdout.strip()
        except:
            return ""
    
    def cmd_limits(self):
        print(f"\n{Colors.CYAN}=== RESOURCE USAGE ==={Colors.NC}")
        print(f"  Images:     {self.count_images()}/{MAX_IMAGES}")
        print(f"  Containers: {self.count_containers(True)}/{MAX_CONTAINERS}")
        print(f"  Compose:    {self.count_stacks()}/{MAX_COMPOSE}")
    
    def cmd_image_ls(self):
        print(f"\n{Colors.CYAN}📦 IMAGES ({self.count_images()}/{MAX_IMAGES}):{Colors.NC}")
        self.run_cmd("docker images --format 'table {{.Repository}}:{{.Tag}}\t{{.ID}}\t{{.Size}}'")
    
    def cmd_image_pull(self, image):
        current = self.count_images()
        if not self.check_limit(current, MAX_IMAGES, "images"):
            return
        print(f"{Colors.YELLOW}Pulling {image}...{Colors.NC}")
        self.run_cmd(f"docker pull {image}")
    
    def cmd_image_rm(self, img_id):
        print(f"{Colors.YELLOW}Removing image...{Colors.NC}")
        self.run_cmd(f"docker rmi {img_id}")
    
    def cmd_container_ls(self, all_c=False):
        total = self.count_containers(True)
        running = self.count_containers(False)
        print(f"\n{Colors.GREEN}🐳 CONTAINERS ({running}/{total} running, max {MAX_CONTAINERS}):{Colors.NC}")
        cmd = "docker ps" + (" -a" if all_c else "")
        cmd += " --format 'table {{.Names}}\t{{.Status}}\t{{.Image}}\t{{.Ports}}'"
        self.run_cmd(cmd)
    
    def cmd_container_run(self, image):
        current = self.count_containers(True)
        if not self.check_limit(current, MAX_CONTAINERS, "containers"):
            return
        
        print(f"{Colors.YELLOW}Running {image}...{Colors.NC}")
        
        check = self.run_cmd_capture(f"docker image inspect {image} 2>/dev/null && echo 'exists'")
        if not check:
            print(f"{Colors.YELLOW}Image not found, pulling...{Colors.NC}")
            if not self.check_limit(self.count_images(), MAX_IMAGES, "images"):
                return
            self.run_cmd(f"docker pull {image}")
        
        name = input("Container name (optional): ").strip()
        port = input("Port (e.g., 8080:80, or press Enter): ").strip()
        
        cmd = "docker run -d" if input("Run in background? [Y/n]: ").lower() != 'n' else "docker run -it"
        if name:
            cmd += f" --name {name}"
        if port:
            cmd += f" -p {port}"
        cmd += f" {image}"
        
        if input("Run this container? [Y/n]: ").lower() != 'n':
            self.run_cmd(cmd)
    
    def cmd_container_stop(self, name):
        self.run_cmd(f"docker stop {name}")
    
    def cmd_container_start(self, name):
        self.run_cmd(f"docker start {name}")
    
    def cmd_container_restart(self, name):
        self.run_cmd(f"docker restart {name}")
    
    def cmd_container_rm(self, name):
        self.run_cmd(f"docker rm -f {name}")
    
    def cmd_container_logs(self, name, follow=False):
        cmd = f"docker logs --tail 50"
        if follow:
            cmd += " -f"
        self.run_cmd(f"{cmd} {name}")
    
    def cmd_volume_ls(self):
        print(f"\n{Colors.CYAN}💾 VOLUMES:{Colors.NC}")
        self.run_cmd("docker volume ls")
    
    def cmd_compose_ls(self):
        print(f"\n{Colors.CYAN}📚 STACKS ({self.count_stacks()}/{MAX_COMPOSE}):{Colors.NC}")
        if not self.stacks_dir.exists():
            return
        for stack in self.stacks_dir.iterdir():
            if stack.is_dir() and (stack/'docker-compose.yml').exists():
                status = self.run_cmd_capture(f"cd '{stack}' && docker compose ps --format json 2>/dev/null")
                if 'running' in status:
                    print(f"  {Colors.GREEN}●{Colors.NC} {stack.name}")
                else:
                    print(f"  {Colors.YELLOW}○{Colors.NC} {stack.name}")
    
    def cmd_compose_create(self):
        current = self.count_stacks()
        if not self.check_limit(current, MAX_COMPOSE, "compose stacks"):
            return
        
        name = input("Stack name: ").strip()
        if not name:
            return
        
        stack_path = self.stacks_dir / name
        if stack_path.exists():
            print(f"{Colors.RED}Stack exists{Colors.NC}")
            return
        
        stack_path.mkdir()
        print(f"{Colors.YELLOW}Paste docker-compose.yml (Ctrl+D then Enter):{Colors.NC}")
        content = sys.stdin.read()
        
        if content.strip():
            (stack_path/'docker-compose.yml').write_text(content)
            print(f"{Colors.GREEN}✓ Stack created{Colors.NC}")
            
            if input("Start now? [y/N]: ").lower() == 'y':
                self.run_cmd(f"cd '{stack_path}' && docker compose up -d")
    
    def cmd_compose_start(self, name):
        stack_path = self.stacks_dir / name
        if stack_path.exists():
            self.run_cmd(f"cd '{stack_path}' && docker compose up -d")
    
    def cmd_compose_stop(self, name):
        stack_path = self.stacks_dir / name
        if stack_path.exists():
            self.run_cmd(f"cd '{stack_path}' && docker compose down")
    
    def cmd_compose_logs(self, name, follow=False):
        stack_path = self.stacks_dir / name
        if stack_path.exists():
            cmd = f"cd '{stack_path}' && docker compose logs --tail 50"
            if follow:
                cmd += " -f"
            self.run_cmd(cmd)
    
    def cmd_dns_ls(self):
        hosts = self.dns_dir / 'hosts'
        if hosts.exists():
            print(f"\n{Colors.CYAN}🌐 DNS ENTRIES (.{self.dns_domain}):{Colors.NC}")
            with open(hosts) as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith('#'):
                        parts = line.split()
                        if len(parts) >= 2:
                            ip, domain = parts[0], parts[1]
                            color = Colors.GREEN if ip == self.server_ip else ''
                            print(f"  {color}{ip:<15}{Colors.NC} {domain}")
    
    def cmd_version(self):
        docker_v = self.run_cmd_capture("docker --version | cut -d' ' -f3 | sed 's/,//'")
        print(f"\n{Colors.BLUE}=== VERSIONS ==={Colors.NC}")
        print(f"  OmniPanel: 1.0.0 (Simple Edition)")
        print(f"  Docker:    {docker_v}")
        print(f"  Server IP: {self.server_ip}")
    
    def run(self):
        print(f"\n{Colors.BLUE}OmniPanel V1.0 - Simple Edition{Colors.NC}")
        print(f"{Colors.YELLOW}Limits: {MAX_IMAGES} Images | {MAX_CONTAINERS} Containers | {MAX_COMPOSE} Stacks{Colors.NC}")
        
        while True:
            try:
                cmd_line = input(f"\n{Colors.GREEN}omni>{Colors.NC} ").strip()
                
                if not cmd_line:
                    continue
                
                parts = cmd_line.split()
                cmd = parts[0].lower()
                args = parts[1:]
                
                if cmd in ['exit', 'quit']:
                    print(f"{Colors.GREEN}Goodbye!{Colors.NC}")
                    break
                    
                elif cmd == 'clear':
                    os.system('clear')
                    
                elif cmd == 'help':
                    self.print_help()
                    
                elif cmd == 'version':
                    self.cmd_version()
                    
                elif cmd == 'limits':
                    self.cmd_limits()
                    
                elif cmd == 'image':
                    if not args or args[0] == 'ls':
                        self.cmd_image_ls()
                    elif args[0] == 'pull' and len(args) > 1:
                        self.cmd_image_pull(args[1])
                    elif args[0] == 'rm' and len(args) > 1:
                        self.cmd_image_rm(args[1])
                    else:
                        print(f"{Colors.RED}Unknown image command{Colors.NC}")
                
                elif cmd == 'container':
                    if not args:
                        self.cmd_container_ls()
                    elif args[0] == 'ls':
                        self.cmd_container_ls('-a' in args)
                    elif args[0] == 'run' and len(args) > 1:
                        self.cmd_container_run(args[1])
                    elif args[0] == 'stop' and len(args) > 1:
                        self.cmd_container_stop(args[1])
                    elif args[0] == 'start' and len(args) > 1:
                        self.cmd_container_start(args[1])
                    elif args[0] == 'restart' and len(args) > 1:
                        self.cmd_container_restart(args[1])
                    elif args[0] == 'rm' and len(args) > 1:
                        self.cmd_container_rm(args[1])
                    elif args[0] == 'logs' and len(args) > 1:
                        self.cmd_container_logs(args[1], '-f' in args)
                    else:
                        print(f"{Colors.RED}Unknown container command{Colors.NC}")
                
                elif cmd == 'volume':
                    if not args or args[0] == 'ls':
                        self.cmd_volume_ls()
                    else:
                        print(f"{Colors.RED}Unknown volume command{Colors.NC}")
                
                elif cmd == 'compose':
                    if not args or args[0] == 'ls':
                        self.cmd_compose_ls()
                    elif args[0] == 'create':
                        self.cmd_compose_create()
                    elif args[0] == 'start' and len(args) > 1:
                        self.cmd_compose_start(args[1])
                    elif args[0] == 'stop' and len(args) > 1:
                        self.cmd_compose_stop(args[1])
                    elif args[0] == 'logs' and len(args) > 1:
                        self.cmd_compose_logs(args[1], '-f' in args)
                    else:
                        print(f"{Colors.RED}Unknown compose command{Colors.NC}")
                
                elif cmd == 'dns':
                    if not args or args[0] == 'ls':
                        self.cmd_dns_ls()
                    else:
                        print(f"{Colors.RED}Unknown dns command{Colors.NC}")
                
                else:
                    print(f"{Colors.RED}Unknown command: {cmd}{Colors.NC}")
                    print(f"Type '{Colors.YELLOW}help{Colors.NC}' for commands")
                    
            except KeyboardInterrupt:
                print(f"\n{Colors.YELLOW}Use 'exit' to quit{Colors.NC}")
            except EOFError:
                print(f"\n{Colors.GREEN}Goodbye!{Colors.NC}")
                break
            except Exception as e:
                print(f"{Colors.RED}Error: {e}{Colors.NC}")

if __name__ == "__main__":
    try:
        OmniPanel().run()
    except KeyboardInterrupt:
        print(f"\n{Colors.GREEN}Goodbye!{Colors.NC}")
        sys.exit(0)
EOF

    chown "$PANEL_USER:$PANEL_USER" "$INSTALL_DIR/panel.py"
    chmod 755 "$INSTALL_DIR/panel.py"
    
    log_success "Panel created with resource limits"
}

# =============================================================================
# Show Summary
# =============================================================================
show_summary() {
    SERVER_IP=$(get_server_ip)
    
    clear
    echo -e "${GREEN}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║         OMNIPANEL V1.0 - SIMPLE EDITION                    ║${NC}"
    echo -e "${GREEN}║              INSTALLED SUCCESSFULLY                        ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    echo -e "${WHITE}Access:{NC}"
    echo "  SSH:  ssh -p $SSH_PORT $PANEL_USER@localhost"
    echo "  Pass: (your custom password)"
    echo
    echo -e "${WHITE}Server IP:{NC} $SERVER_IP"
    echo -e "${WHITE}DNS Domain:{NC} .$DNS_DOMAIN"
    echo
    echo -e "${WHITE}Resource Limits:{NC}"
    echo "  Maximum Images:      $MAX_IMAGES"
    echo "  Maximum Containers:  $MAX_CONTAINERS"
    echo "  Maximum Compose:     $MAX_COMPOSE"
    echo
    echo -e "${WHITE}Quick Commands:{NC}"
    echo "  omni> limits                  # Show current usage"
    echo "  omni> container run nginx:latest  # Run nginx"
    echo "  omni> container ls             # List containers"
    echo "  omni> image pull alpine        # Pull image"
    echo "  omni> dns ls                   # Show DNS entries"
    echo "  omni> exit                     # Exit panel"
    echo
    echo -e "${YELLOW}Uninstall:{NC}"
    echo "  sudo $0 uninstall       # Remove OmniPanel"
    echo
}

# =============================================================================
# Uninstall
# =============================================================================
uninstall() {
    echo -e "${YELLOW}========================================${NC}"
    echo -e "${YELLOW}   OMNIPANEL UNINSTALL                  ${NC}"
    echo -e "${YELLOW}========================================${NC}"
    echo ""
    
    read -p "Proceed with uninstall? [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo -e "${GREEN}Cancelled${NC}"
        exit 0
    fi
    
    echo ""
    log_step "Stopping OmniPanel services..."
    
    systemctl stop omnipanel-dns 2>/dev/null || true
    systemctl disable omnipanel-dns 2>/dev/null || true
    systemctl stop omnipanel-dns-update.timer 2>/dev/null || true
    systemctl disable omnipanel-dns-update.timer 2>/dev/null || true
    
    rm -f /etc/systemd/system/omnipanel-dns.service
    rm -f /etc/systemd/system/omnipanel-dns-update.service
    rm -f /etc/systemd/system/omnipanel-dns-update.timer
    systemctl daemon-reload
    
    log_step "Removing SSH configuration..."
    sed -i '/^Match User omnipanel/,/^$/d' /etc/ssh/sshd_config
    sed -i "s/^Port $SSH_PORT/# Port $SSH_PORT (removed)/" /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || true
    
    log_step "Removing sudoers configuration..."
    rm -f /etc/sudoers.d/omnipanel
    
    echo ""
    log_step "Removing user..."
    userdel -r "$PANEL_USER" 2>/dev/null || true
    
    log_step "Removing directories..."
    rm -rf "$INSTALL_DIR"
    
    echo ""
    echo -e "${GREEN}========================================${NC}"
    echo -e "${GREEN}   Uninstall Complete                   ${NC}"
    echo -e "${GREEN}========================================${NC}"
}

# =============================================================================
# Main Install
# =============================================================================
main() {
    clear
    echo -e "${BLUE}╔════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║         OMNIPANEL V1.0 - SIMPLE EDITION                    ║${NC}"
    echo -e "${BLUE}║     Limited: 6 Images | 10 Containers | 5 Compose Stacks   ║${NC}"
    echo -e "${BLUE}╚════════════════════════════════════════════════════════════╝${NC}"
    echo
    
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}Please run as root${NC}"
        exit 1
    fi
    
    detect_os
    install_dependencies
    install_docker
    setup_user
    setup_directories
    setup_ssh
    setup_venv
    setup_dns
    setup_limits
    create_panel
    
    chown -R "$PANEL_USER:$PANEL_USER" "$INSTALL_DIR"
    
    show_summary
}

# =============================================================================
# Script Entry
# =============================================================================
case "${1:-install}" in
    install)
        main
        ;;
    uninstall)
        uninstall
        ;;
    password)
        if [ -f "$INSTALL_DIR/.password" ]; then
            echo -e "${GREEN}Password: $(cat $INSTALL_DIR/.password)${NC}"
        else
            echo -e "${RED}Password file not found${NC}"
        fi
        ;;
    help)
        echo "Usage: $0 {install|uninstall|password}"
        echo "  install   - Install OmniPanel V1.0 Simple Edition"
        echo "  uninstall - Remove OmniPanel"
        echo "  password  - Show current password"
        ;;
    *)
        echo "Usage: $0 {install|uninstall|password}"
        exit 1
        ;;
esac