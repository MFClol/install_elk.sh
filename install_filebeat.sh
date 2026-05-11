#!/bin/bash
# =============================================================================
# Установка Filebeat на сервер с nginx (mysql-master, 192.168.50.24)
# Отправляет логи на Logstash (ELK-сервер 192.168.50.48:5400)
# =============================================================================

set -e
export DEBIAN_FRONTEND=noninteractive

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

die() {
    echo -e "${RED}ОШИБКА: $1${NC}" >&2
    exit 1
}

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка Filebeat для сбора логов nginx ===${NC}"
echo -e "${GREEN}============================================${NC}"

# -----------------------------------------------------------------------------
# 1. Проверка/установка nginx
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 1. Проверка nginx...${NC}"
if ! systemctl is-active --quiet nginx; then
    echo -e "${YELLOW}nginx не установлен. Устанавливаем...${NC}"
    apt update -qq
    apt install -y -qq nginx
    systemctl start nginx
    systemctl enable nginx
    echo -e "${GREEN}✓ nginx установлен и запущен${NC}"
else
    echo -e "${GREEN}✓ nginx уже работает${NC}"
fi

# -----------------------------------------------------------------------------
# 2. Проверка соединения с ELK-сервером
# -----------------------------------------------------------------------------
ELK_HOST="192.168.50.48"
LOGSTASH_PORT="5400"

echo -e "${YELLOW}==> 2. Проверка связи с ELK-сервером ($ELK_HOST)...${NC}"
if ping -c 1 $ELK_HOST >/dev/null 2>&1; then
    echo -e "${GREEN}✓ Соединение с $ELK_HOST установлено${NC}"
else
    echo -e "${RED}✗ Нет соединения с $ELK_HOST${NC}"
    die "Убедитесь, что ELK-сервер запущен и доступен по сети."
fi

# -----------------------------------------------------------------------------
# 3. Установка Filebeat (локально или из сети)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 3. Установка Filebeat...${NC}"

# Путь к локальному deb-пакету (точное имя, как у вас)
FB_DEB_LOCAL="/home/admin/filebeat_8.17.1_amd64-224190-6bb8de.deb"

if [ -f "$FB_DEB_LOCAL" ]; then
    echo -e "${GREEN}Найден локальный пакет: $FB_DEB_LOCAL${NC}"
    dpkg -i "$FB_DEB_LOCAL"
else
    echo -e "${YELLOW}Локальный пакет не найден. Скачиваю с зеркала Яндекса...${NC}"
    wget -q --show-progress https://mirror.yandex.ru/mirrors/elastic/8.17.1/filebeat-8.17.1-amd64.deb -O /tmp/filebeat.deb
    dpkg -i /tmp/filebeat.deb
    rm -f /tmp/filebeat.deb
fi

# -----------------------------------------------------------------------------
# 4. Настройка Filebeat
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 4. Настройка Filebeat...${NC}"
cat > /etc/filebeat/filebeat.yml <<EOF
filebeat.inputs:
- type: filestream
  enabled: true
  paths:
    - /var/log/nginx/*.log
  exclude_files: ['\.gz$']

output.logstash:
  hosts: ["$ELK_HOST:$LOGSTASH_PORT"]

processors:
  - add_host_metadata: ~
  - add_cloud_metadata: ~
EOF

# -----------------------------------------------------------------------------
# 5. Запуск и включение автозагрузки
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 5. Запуск Filebeat...${NC}"
systemctl daemon-reload
systemctl start filebeat
systemctl enable filebeat

# -----------------------------------------------------------------------------
# 6. Генерация тестовых запросов к nginx (чтобы появились логи)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 6. Генерация тестового трафика...${NC}"
for i in {1..5}; do
    curl -s http://localhost/ > /dev/null
    curl -s http://localhost/test$i > /dev/null
done
echo -e "${GREEN}✓ Сгенерировано 10 тестовых запросов${NC}"

# -----------------------------------------------------------------------------
# 7. Проверка статуса
# -----------------------------------------------------------------------------
sleep 3
echo -e "${YELLOW}==> 7. Статус Filebeat:${NC}"
systemctl status filebeat --no-pager -l

# -----------------------------------------------------------------------------
# 8. Итог
# -----------------------------------------------------------------------------
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка Filebeat завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Filebeat отправляет логи nginx на ${YELLOW}$ELK_HOST:$LOGSTASH_PORT${NC}"
echo -e "\nПроверьте на сервере ELK (log1):"
echo -e "  curl http://localhost:9200/_cat/indices | grep weblogs"
echo -e "  sudo journalctl -u logstash -f"
echo -e "\nОткройте Kibana: ${YELLOW}http://192.168.50.48:5601${NC} и создайте index pattern 'weblogs-*'"
