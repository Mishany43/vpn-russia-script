#!/bin/bash
# ==============================================================================
# WireGuard Config Generator
# Универсальный генератор конфигураций WireGuard
# ==============================================================================

set -e  # Прерывать при ошибках

# ==============================================================================
# КОНФИГУРАЦИЯ
# ==============================================================================
CONFIG_DIR="${WG_CONFIG_DIR:-$HOME/wireguard-configs}"
LOG_FILE="$CONFIG_DIR/wg-generator.log"
DEFAULT_PORT="51820"
DEFAULT_DNS="1.1.1.1, 8.8.8.8"
DEFAULT_ALLOWED_IPS="0.0.0.0/0, ::/0"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ==============================================================================
# ФУНКЦИИ ЛОГИРОВАНИЯ
# ==============================================================================
log() {
    local level="$1"
    local message="$2"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo -e "${timestamp} [${level}] ${message}" | tee -a "$LOG_FILE"
}

log_info() { log "INFO" "${BLUE}$1${NC}"; }
log_success() { log "SUCCESS" "${GREEN}$1${NC}"; }
log_warning() { log "WARNING" "${YELLOW}$1${NC}"; }
log_error() { log "ERROR" "${RED}$1${NC}"; }

# ==============================================================================
# ФУНКЦИИ ПРОВЕРКИ
# ==============================================================================
check_dependencies() {
    local deps=("wg" "jq" "curl" "qrencode")
    local missing=()
    
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done
    
    if [ ${#missing[@]} -gt 0 ]; then
        log_warning "Необходимо установить: ${missing[*]}"
        read -p "Установить автоматически? (y/N): " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            sudo apt update
            sudo apt install -y wireguard-tools jq curl qrencode 2>/dev/null || \
            sudo yum install -y wireguard-tools jq curl qrencode 2>/dev/null || \
            sudo pacman -S --noconfirm wireguard-tools jq curl qrencode 2>/dev/null
        else
            log_error "Зависимости не установлены"
            exit 1
        fi
    fi
}

init_dirs() {
    mkdir -p "$CONFIG_DIR/servers" "$CONFIG_DIR/clients" "$CONFIG_DIR/backups"
    log_info "Рабочая директория: $CONFIG_DIR"
}

# ==============================================================================
# ФУНКЦИИ ГЕНЕРАЦИИ КЛЮЧЕЙ
# ==============================================================================
generate_keys() {
    local prefix="${1:-client}"
    local timestamp=$(date +%Y%m%d_%H%M%S)
    
    local private_key=$(wg genkey)
    local public_key=$(echo "$private_key" | wg pubkey)
    local preshared_key=$(wg genpsk 2>/dev/null || echo "")
    
    # Сохраняем ключи в файл
    local key_file="$CONFIG_DIR/clients/${prefix}_${timestamp}.keys"
    cat > "$key_file" << EOF
# WireGuard Keys: ${prefix}_${timestamp}
PRIVATE_KEY=${private_key}
PUBLIC_KEY=${public_key}
PRESHARED_KEY=${preshared_key}
GENERATED=$(date)
EOF
    
    chmod 600 "$key_file"
    
    echo "$private_key:$public_key:$preshared_key:$key_file"
    log_success "Ключи сгенерированы: $key_file"
}

# ==============================================================================
# ФУНКЦИИ СОЗДАНИЯ КОНФИГОВ
# ==============================================================================
create_server_config() {
    local server_name="${1:-wg-server}"
    local server_ip="${2:-10.0.0.1}"
    local port="${3:-$DEFAULT_PORT}"
    local interface="${4:-eth0}"
    
    local keys=$(generate_keys "$server_name")
    IFS=':' read -r private_key public_key preshared_key key_file <<< "$keys"
    
    local config_file="$CONFIG_DIR/servers/${server_name}.conf"
    
    cat > "$config_file" << EOF
# ==============================================================================
# WireGuard Server: ${server_name}
# Generated: $(date)
# ==============================================================================
[Interface]
Address = ${server_ip}/24
ListenPort = ${port}
PrivateKey = ${private_key}
PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o ${interface} -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o ${interface} -j MASQUERADE
SaveConfig = true

# Дополнительные настройки
# MTU = 1420
# Table = auto
# PreUp = 
# PreDown = 

# ==============================================================================
# Клиенты добавляются ниже
# ==============================================================================
# [Peer]
# PublicKey = <client_public_key>
# AllowedIPs = 10.0.0.2/32
# PresharedKey = <optional_preshared_key>
EOF
    
    chmod 600 "$config_file"
    
    log_success "Конфиг сервера создан: $config_file"
    echo "public_key:$public_key|config:$config_file|keys:$key_file"
}

create_client_config() {
    local client_name="${1:-client}"
    local server_public_key="$2"
    local server_endpoint="$3"
    local server_port="${4:-$DEFAULT_PORT}"
    local client_ip="$5"
    local dns_servers="${6:-$DEFAULT_DNS}"
    
    local keys=$(generate_keys "$client_name")
    IFS=':' read -r private_key public_key preshared_key key_file <<< "$keys"
    
    local config_file="$CONFIG_DIR/clients/${client_name}.conf"
    
    cat > "$config_file" << EOF
[Interface]
PrivateKey = ${private_key}
Address = ${client_ip}/24
DNS = ${dns_servers}
MTU = 1280

[Peer]
PublicKey = ${server_public_key}
Endpoint = ${server_endpoint}:${server_port}
AllowedIPs = ${DEFAULT_ALLOWED_IPS}
$( [ -n "$preshared_key" ] && echo "PresharedKey = $preshared_key" )
PersistentKeepalive = 25
EOF
    
    chmod 600 "$config_file"
    
    log_success "Конфиг клиента создан: $config_file"
    echo "private_key:$private_key|public_key:$public_key|config:$config_file"
}

# ==============================================================================
# ФУНКЦИИ ДЛЯ РАБОТЫ С ВНЕШНИМИ API
# ==============================================================================
fetch_external_config() {
    local service="$1"
    local config_name="$2"
    
    case "$service" in
        "mullvad")
            # Пример для Mullvad VPN
            local server_data=$(curl -s "https://api.mullvad.net/public/relays/wireguard/v1/" | \
                jq -r '.countries[] | select(.code == "us") | .cities[].relays[] | select(.type == "wireguard") | "\(.hostname) \(.public_key) \(.ipv4_addr_in)"' | \
                head -1)
            echo "$server_data"
            ;;
        "ivpn")
            # Пример для IVPN
            local server_data=$(curl -s "https://api.ivpn.net/v4/servers/stats" | \
                jq -r '.wireguard[] | select(.country_code == "US") | "\(.hostname) \(.public_key) \(.ip_address)"' | \
                head -1)
            echo "$server_data"
            ;;
        *)
            log_error "Сервис $service не поддерживается"
            return 1
            ;;
    esac
}

# ==============================================================================
# QR-КОД И ЭКСПОРТ
# ==============================================================================
generate_qr() {
    local config_file="$1"
    local output_type="${2:-utf8}"  # utf8, png, ansi
    
    if [ ! -f "$config_file" ]; then
        log_error "Файл конфигурации не найден: $config_file"
        return 1
    fi
    
    log_info "Генерация QR-кода для: $(basename "$config_file")"
    
    case "$output_type" in
        "utf8")
            qrencode -t UTF8 < "$config_file"
            ;;
        "ansi")
            qrencode -t ANSIUTF8 < "$config_file"
            ;;
        "png")
            local png_file="${config_file%.conf}.png"
            qrencode -o "$png_file" < "$config_file"
            log_success "QR-код сохранен: $png_file"
            ;;
        *)
            qrencode -t UTF8 < "$config_file"
            ;;
    esac
}

export_config() {
    local config_file="$1"
    local format="$2"
    
    case "$format" in
        "base64")
            base64 -w0 "$config_file"
            ;;
        "json")
            cat "$config_file" | jq -R -s 'split("\n")' 
            ;;
        "archive")
            local archive_name="$CONFIG_DIR/backups/wg_$(date +%Y%m%d_%H%M%S).tar.gz"
            tar -czf "$archive_name" -C "$CONFIG_DIR" servers/ clients/
            log_success "Архив создан: $archive_name"
            ;;
        *)
            cat "$config_file"
            ;;
    esac
}

# ==============================================================================
# ИНТЕРАКТИВНЫЙ РЕЖИМ
# ==============================================================================
interactive_menu() {
    clear
    echo -e "${CYAN}"
    cat << "EOF"
╔═══════════════════════════════════════════╗
║      WireGuard Config Generator v1.0      ║
║         Универсальный генератор           ║
╚═══════════════════════════════════════════╝
EOF
    echo -e "${NC}"
    
    while true; do
        echo -e "\n${BLUE}ГЛАВНОЕ МЕНЮ:${NC}"
        echo "1) Создать конфигурацию сервера"
        echo "2) Создать конфигурацию клиента"
        echo "3) Подключиться к внешнему VPN (Mullvad/IVPN)"
        echo "4) Показать существующие конфиги"
        echo "5) Сгенерировать QR-код"
        echo "6) Тест подключения"
        echo "7) Управление ключами"
        echo "8) Выход"
        
        read -p "Выберите опцию [1-8]: " choice
        
        case $choice in
            1)
                echo -e "\n${YELLOW}СОЗДАНИЕ СЕРВЕРА:${NC}"
                read -p "Имя сервера [wg-server]: " server_name
                read -p "IP сервера [10.0.0.1]: " server_ip
                read -p "Порт [51820]: " port
                read -p "Интерфейс [eth0]: " interface
                
                server_name="${server_name:-wg-server}"
                server_ip="${server_ip:-10.0.0.1}"
                port="${port:-51820}"
                interface="${interface:-eth0}"
                
                result=$(create_server_config "$server_name" "$server_ip" "$port" "$interface")
                IFS='|' read -ra parts <<< "$result"
                
                for part in "${parts[@]}"; do
                    IFS=':' read -r key value <<< "$part"
                    echo -e "${GREEN}${key}:${NC} $value"
                done
                ;;
            2)
                echo -e "\n${YELLOW}СОЗДАНИЕ КЛИЕНТА:${NC}"
                read -p "Имя клиента: " client_name
                read -p "Публичный ключ сервера: " server_pubkey
                read -p "Endpoint сервера (IP/домен): " endpoint
                read -p "Порт сервера [51820]: " port
                read -p "IP клиента [10.0.0.2]: " client_ip
                
                [ -z "$client_name" ] && { log_error "Имя клиента обязательно"; continue; }
                
                port="${port:-51820}"
                client_ip="${client_ip:-10.0.0.2}"
                
                result=$(create_client_config "$client_name" "$server_pubkey" "$endpoint" "$port" "$client_ip")
                IFS='|' read -ra parts <<< "$result"
                
                config_file=$(echo "$result" | grep -o "config:[^|]*" | cut -d: -f2)
                
                echo -e "\n${GREEN}Конфиг создан:${NC} $config_file"
                echo -e "\n${CYAN}QR-код конфигурации:${NC}"
                generate_qr "$config_file"
                ;;
            3)
                echo -e "\n${YELLOW}ВНЕШНИЕ VPN-СЕРВИСЫ:${NC}"
                echo "1) Mullvad (США)"
                echo "2) IVPN (США)"
                echo "3) Назад"
                
                read -p "Выберите сервис: " vpn_choice
                
                case $vpn_choice in
                    1|2)
                        service=$([ "$vpn_choice" = "1" ] && echo "mullvad" || echo "ivpn")
                        echo -e "\n${YELLOW}Получение данных от $service...${NC}"
                        
                        server_data=$(fetch_external_config "$service")
                        if [ -n "$server_data" ]; then
                            read hostname pubkey ip <<< "$server_data"
                            
                            read -p "Имя клиента [${service}_client]: " client_name
                            client_name="${client_name:-${service}_client}"
                            
                            result=$(create_client_config "$client_name" "$pubkey" "$ip" "51820" "10.0.0.100")
                            config_file=$(echo "$result" | grep -o "config:[^|]*" | cut -d: -f2)
                            
                            echo -e "\n${GREEN}Подключение к ${service} настроено!${NC}"
                            echo "Сервер: $hostname"
                            echo "Конфиг: $config_file"
                            
                            generate_qr "$config_file"
                        fi
                        ;;
                esac
                ;;
            4)
                echo -e "\n${YELLOW}СУЩЕСТВУЮЩИЕ КОНФИГИ:${NC}"
                echo -e "${BLUE}Серверы:${NC}"
                ls -la "$CONFIG_DIR/servers/" 2>/dev/null || echo "  Нет серверов"
                echo -e "\n${BLUE}Клиенты:${NC}"
                ls -la "$CONFIG_DIR/clients/" 2>/dev/null || echo "  Нет клиентов"
                ;;
            5)
                echo -e "\n${YELLOW}ГЕНЕРАЦИЯ QR-КОДА:${NC}"
                read -p "Путь к файлу конфигурации: " qr_file
                if [ -f "$qr_file" ]; then
                    generate_qr "$qr_file" "utf8"
                else
                    log_error "Файл не найден: $qr_file"
                fi
                ;;
            6)
                echo -e "\n${YELLOW}ТЕСТ ПОДКЛЮЧЕНИЯ:${NC}"
                read -p "IP для теста [8.8.8.8]: " test_ip
                test_ip="${test_ip:-8.8.8.8}"
                
                if ping -c 3 "$test_ip" &> /dev/null; then
                    log_success "Интернет соединение работает"
                else
                    log_warning "Нет интернет соединения"
                fi
                ;;
            7)
                echo -e "\n${YELLOW}УПРАВЛЕНИЕ КЛЮЧАМИ:${NC}"
                echo "1) Сгенерировать новые ключи"
                echo "2) Показать существующие ключи"
                echo "3) Проверить ключ"
                echo "4) Назад"
                
                read -p "Выберите: " key_choice
                
                case $key_choice in
                    1)
                        read -p "Префикс для ключей: " prefix
                        generate_keys "$prefix"
                        ;;
                    2)
                        echo -e "\n${BLUE}Список ключей:${NC}"
                        find "$CONFIG_DIR" -name "*.keys" -exec ls -la {} \;
                        ;;
                    3)
                        read -p "Введите приватный ключ: " check_key
                        if echo "$check_key" | wg pubkey &>/dev/null; then
                            log_success "Ключ валиден"
                        else
                            log_error "Неверный ключ"
                        fi
                        ;;
                esac
                ;;
            8)
                echo -e "\n${GREEN}Выход. Конфиги сохранены в: $CONFIG_DIR${NC}"
                exit 0
                ;;
            *)
                log_error "Неверный выбор"
                ;;
        esac
        
        echo -e "\n${CYAN}Нажмите Enter для продолжения...${NC}"
        read
        clear
    done
}

# ==============================================================================
# КОМАНДНЫЙ РЕЖИМ
# ==============================================================================
cmd_server() {
    local server_name="$1"
    local server_ip="$2"
    local port="$3"
    
    create_server_config "${server_name:-wg-server}" "${server_ip:-10.0.0.1}" "${port:-51820}"
}

cmd_client() {
    local client_name="$1"
    local server_pubkey="$2"
    local server_endpoint="$3"
    
    if [ -z "$client_name" ] || [ -z "$server_pubkey" ] || [ -z "$server_endpoint" ]; then
        echo "Использование: $0 --client <имя> <публичный_ключ> <endpoint> [порт] [ip]"
        exit 1
    fi
    
    create_client_config "$client_name" "$server_pubkey" "$server_endpoint" "${4:-51820}" "${5:-10.0.0.2}"
}

cmd_scan() {
    local subnet="${1:-10.0.0.0/24}"
    log_info "Сканирование WireGuard серверов в сети $subnet..."
    
    # Просто пример - в реальности нужен более сложный сканер
    nmap -sU -p 51820 "$subnet" --open 2>/dev/null | grep -oP '\d+\.\d+\.\d+\.\d+' | while read ip; do
        echo "Найден возможный WG сервер: $ip"
    done
}

# ==============================================================================
# ОСНОВНАЯ ЛОГИКА
# ==============================================================================
main() {
    check_dependencies
    init_dirs
    
    # Обработка аргументов командной строки
    if [ $# -gt 0 ]; then
        case "$1" in
            --server|-s)
                cmd_server "$2" "$3" "$4"
                ;;
            --client|-c)
                cmd_client "$2" "$3" "$4" "$5" "$6"
                ;;
            --scan)
                cmd_scan "$2"
                ;;
            --qrcode|-q)
                generate_qr "$2" "${3:-utf8}"
                ;;
            --export|-e)
                export_config "$2" "$3"
                ;;
            --help|-h)
                cat << EOF
WireGuard Config Generator

Использование:
  $0 [опции]

Опции:
  -s, --server [name] [ip] [port]   Создать серверный конфиг
  -c, --client name pubkey endpoint  Создать клиентский конфиг
  --scan [subnet]                    Сканировать сеть на WG серверы
  -q, --qrcode file [type]           Создать QR-код
  -e, --export file [format]         Экспортировать конфиг
  -h, --help                         Показать эту справку

Примеры:
  $0 --server my-vpn 10.0.0.1 51820
  $0 --client laptop ABCDEF... 192.168.1.100
  $0  # интерактивный режим
EOF
                ;;
            *)
                log_error "Неизвестная опция: $1"
                exit 1
                ;;
        esac
    else
        interactive_menu
    fi
}

# ==============================================================================
# ЗАПУСК
# ==============================================================================
trap 'log_error "Скрипт прерван пользователем"; exit 1' INT
main "$@"