#!/bin/bash
# ============================================
# Скрипт установки Filebeat для сбора логов nginx
# Выполнять на сервере с установленным nginx
# ELK сервер: 192.168.50.186
# ============================================

set -e  # Остановка при ошибке

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# ============================================
# 0. Конфигурационные переменные
# ============================================
# IP-адрес сервера ELK (измените при необходимости)
ELK_SERVER_IP="192.168.50.186"
# Порт Logstash
LOGSTASH_PORT="5400"

# ============================================
# 1. Проверка наличия nginx
# ============================================
print_header() {
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}============================================${NC}"
}

print_info() {
    echo -e "${YELLOW}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_header "=== Установка Filebeat для сбора логов nginx ==="

print_info "Проверка наличия nginx..."

# Проверяем, установлен ли nginx
if ! command -v nginx > /dev/null 2>&1; then
    print_info "nginx не найден. Установка nginx..."
    apt update -qq
    apt install -y nginx
    systemctl start nginx
    systemctl enable nginx
    print_success "nginx установлен и запущен"
else
    print_success "nginx уже установлен"
fi

# Проверяем, есть ли файлы логов nginx
if [ -f /var/log/nginx/access.log ]; then
    print_success "Логи nginx найдены: /var/log/nginx/access.log"
else
    print_error "Логи nginx не найдены!"
    exit 1
fi

# ============================================
# 2. Проверка соединения с ELK сервером
# ============================================
print_info "Проверка соединения с ELK сервером (${ELK_SERVER_IP})..."

if ping -c 1 ${ELK_SERVER_IP} > /dev/null 2>&1; then
    print_success "Соединение с ${ELK_SERVER_IP} установлено"
else
    print_error "Нет соединения с ELK сервером ${ELK_SERVER_IP}"
    print_info "Проверьте:"
    echo "  • Правильно ли указан IP адрес ELK сервера"
    echo "  • Включён ли ELK сервер"
    echo "  • Открыт ли порт 5400 на ELK сервере"
    exit 1
fi

# ============================================
# 3. Скачивание и установка Filebeat
# ============================================
print_header "=== Скачивание и установка Filebeat ==="

cd /tmp

print_info "Скачивание Filebeat 8.17.1 с Яндекс зеркала..."
if wget -q --show-progress https://mirror.yandex.ru/mirrors/elastic/8.17.1/filebeat-8.17.1-amd64.deb; then
    print_success "Filebeat скачан"
else
    print_error "Не удалось скачать Filebeat"
    exit 1
fi

print_info "Установка Filebeat..."
dpkg -i filebeat-8.17.1-amd64.deb
print_success "Filebeat установлен"

# ============================================
# 4. Настройка Filebeat
# ============================================
print_header "=== Настройка Filebeat ==="

# Создаём конфигурационный файл Filebeat
cat > /etc/filebeat/filebeat.yml << EOF
# ======================== Filebeat Configuration ========================
# Документация: https://www.elastic.co/guide/en/beats/filebeat/8.17/

# === ВХОДНЫЕ ДАННЫЕ ===
# Определяем, какие логи читать
filebeat.inputs:
  # Используем filestream (современный способ чтения файлов)
  - type: filestream
    # Включён ли этот input
    enabled: true
    # Пути к файлам логов nginx
    paths:
      - /var/log/nginx/*.log
    # Исключаем сжатые файлы (.gz)
    exclude_files: ['\.gz$']

# === МОДУЛИ ===
# Настройки модулей Filebeat (не используем их)
filebeat.config.modules:
  path: \${path.config}/modules.d/*.yml
  reload.enabled: false

# === ШАБЛОН ИНДЕКСА ===
# Настройки шаблона для Elasticsearch (не критично)
setup.template.settings:
  index.number_of_shards: 1

# === ВЫХОДНЫЕ ДАННЫЕ ===
# Куда отправлять собранные логи
# Закомментирована прямая отправка в Elasticsearch
# output.elasticsearch:
#   hosts: ["localhost:9200"]

# Настроена отправка в Logstash (наш случай)
output.logstash:
  # IP и порт сервера Logstash (ELK сервер)
  hosts: ["${ELK_SERVER_IP}:${LOGSTASH_PORT}"]

# === ПРОЦЕССОРЫ ===
# Добавляем метаданные к каждому событию
processors:
  # Добавляем информацию о хосте (IP, имя хоста)
  - add_host_metadata:
      when.not.contains.tags: forwarded
  # Добавляем облачные метаданные (если сервер в облаке)
  - add_cloud_metadata: ~
  # Добавляем Docker метаданные (если используется Docker)
  - add_docker_metadata: ~
  # Добавляем Kubernetes метаданные (если используется K8s)
  - add_kubernetes_metadata: ~
EOF

print_success "Конфигурация Filebeat создана"

# ============================================
# 5. Запуск Filebeat
# ============================================
print_header "=== Запуск Filebeat ==="

print_info "Запуск Filebeat..."
systemctl daemon-reload
systemctl start filebeat
systemctl enable filebeat
print_success "Filebeat запущен"

# ============================================
# 6. Генерация тестовых запросов
# ============================================
print_header "=== Генерация тестового трафика ==="

print_info "Создание тестовых запросов к nginx..."

# Генерируем несколько запросов для создания логов
for i in {1..10}; do
    # Обычный запрос к главной странице
    curl -s http://localhost/ > /dev/null
    # Запрос к несуществующей странице (для ошибки 404)
    curl -s http://localhost/test-page-${i} > /dev/null
    # Имитация разных User-Agent
    curl -s -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" http://localhost/ > /dev/null
done

print_success "Сгенерировано 30 тестовых запросов"

# Небольшая пауза для отправки логов
sleep 3

# ============================================
# 7. Проверка работоспособности
# ============================================
print_header "=== Проверка работоспособности ==="

# Проверяем статус Filebeat
echo -e "\n${GREEN}--- Статус Filebeat ---${NC}"
if systemctl is-active --quiet filebeat; then
    print_success "Filebeat: АКТИВЕН"
else
    print_error "Filebeat: НЕ АКТИВЕН"
    echo "Проверьте логи: journalctl -u filebeat"
fi

# Показываем последние записи в логах Filebeat
echo -e "\n${GREEN}--- Последние записи в логах Filebeat ---${NC}"
journalctl -u filebeat --no-pager -n 15

# Проверяем отправку данных
echo -e "\n${GREEN}--- Проверка соединения с Logstash ---${NC}"
if nc -zv ${ELK_SERVER_IP} ${LOGSTASH_PORT} 2>&1 | grep -q "succeeded\|Connected"; then
    print_success "Соединение с ${ELK_SERVER_IP}:${LOGSTASH_PORT} установлено"
else
    print_error "Не удалось подключиться к ${ELK_SERVER_IP}:${LOGSTASH_PORT}"
    print_info "Проверьте, что на ELK сервере запущен Logstash и открыт порт 5400"
fi

# ============================================
# 8. Итоговая информация
# ============================================
print_header "=== УСТАНОВКА FILEBEAT УСПЕШНО ЗАВЕРШЕНА ==="

echo -e "${GREEN}Filebeat настроен и отправляет логи на ELK сервер${NC}"
echo ""
echo -e "${YELLOW}Данные логов будут доступны в Kibana через 1-2 минуты${NC}"
echo ""
echo -e "${YELLOW}На сервере ELK (${ELK_SERVER_IP}) выполните:${NC}"
echo "  1. Проверить индексы: curl http://localhost:9200/_cat/indices"
echo "  2. Должен появиться индекс: weblogs-ГГГГ.ММ.ДД"
echo ""
echo -e "${YELLOW}Для просмотра логов Filebeat в реальном времени:${NC}"
echo "  journalctl -u filebeat -f"
echo ""
echo -e "${YELLOW}Для проверки соединения с Logstash:${NC}"
echo "  nc -zv ${ELK_SERVER_IP} ${LOGSTASH_PORT}"
