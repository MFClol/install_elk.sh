#!/bin/bash
# =============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1
# IP: 192.168.50.48
# Версия: 8.17.1
#
# Локальные deb-пакеты (должны лежать в /home/admin/):
#   - elasticsearch_8.17.1_amd64-224190-a8d54b.deb
#   - logstash_8.17.1_amd64-224190-b63239.deb
#   - kibana_8.17.1_amd64-224190-9c79ef.deb
#
# Особенности:
#   - Безопасность отключена (HTTP, без TLS, без авторизации)
#   - Elasticsearch настраивается до первого запуска (чистая конфигурация)
#   - Logstash слушает порт 5400 для приёма логов от Filebeat
#   - Kibana доступна с любого хоста
#   - UFW открывает порты 22, 5601, 5400
# =============================================================================

set -e  # Прерывать скрипт при любой ошибке

# Отключаем интерактивные запросы apt (чтобы установка не задавала вопросов)
export DEBIAN_FRONTEND=noninteractive

# --- Цвета для красивого вывода ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Функция для вывода ошибок и остановки ---
die() {
    echo -e "${RED}ОШИБКА: $1${NC}" >&2
    exit 1
}

# --- Заголовок ---
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack (8.17.1) на log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# =============================================================================
# 1. Установка JDK и вспомогательных утилит
# =============================================================================
echo -e "${YELLOW}==> 1. Установка JDK, wget, curl...${NC}"
apt update -qq
apt install -y -qq default-jdk wget curl

# =============================================================================
# 2. Проверка наличия deb-пакетов
# =============================================================================
echo -e "${YELLOW}==> 2. Проверка локальных deb-пакетов...${NC}"
DEB_DIR="/home/admin"
ES_DEB="$DEB_DIR/elasticsearch_8.17.1_amd64-224190-a8d54b.deb"
LS_DEB="$DEB_DIR/logstash_8.17.1_amd64-224190-b63239.deb"
KB_DEB="$DEB_DIR/kibana_8.17.1_amd64-224190-9c79ef.deb"

for f in "$ES_DEB" "$LS_DEB" "$KB_DEB"; do
    if [ ! -f "$f" ]; then
        die "Не найден файл: $f"
    fi
done
echo -e "${GREEN}✓ Все deb-пакеты найдены в $DEB_DIR${NC}"

# =============================================================================
# 3. Установка Elasticsearch (отдельно, с настройкой до первого запуска)
# =============================================================================
echo -e "${YELLOW}==> 3. Установка Elasticsearch...${NC}"
dpkg -i "$ES_DEB"

# Удаляем автоматически сгенерированные сертификаты и keystore (если они есть)
echo -e "${YELLOW}    Очистка автоматической генерации безопасности...${NC}"
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore

# Создаём конфигурационный файл Elasticsearch (безопасность отключена)
echo -e "${YELLOW}    Настройка elasticsearch.yml...${NC}"
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
# --------------------------- Elasticsearch Configuration ---------------------------
cluster.name: elk-cluster
node.name: elk-node
network.host: 0.0.0.0
http.port: 9200

# Полное отключение безопасности (HTTP, без TLS, без авторизации)
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

# Одноузловой кластер (без discovery)
cluster.initial_master_nodes: ["elk-node"]
discovery.type: single-node
EOF

# Выставляем правильные права на каталог конфигурации
chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

# =============================================================================
# 4. Запуск Elasticsearch
# =============================================================================
echo -e "${YELLOW}==> 4. Запуск Elasticsearch...${NC}"
systemctl start elasticsearch
systemctl enable elasticsearch

# Ожидание готовности (до 30 секунд)
echo -e "${YELLOW}    Ожидание запуска (до 30 сек)...${NC}"
for i in {1..15}; do
    if curl -s http://localhost:9200 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Elasticsearch запущен и отвечает на порту 9200${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 15 ]; then
        echo -e "${RED}⚠️  Внимание: Elasticsearch не запустился за 30 секунд.${NC}"
        echo -e "${YELLOW}    Проверьте: systemctl status elasticsearch, journalctl -u elasticsearch${NC}"
    fi
done

# =============================================================================
# 5. Установка Logstash и Kibana
# =============================================================================
echo -e "${YELLOW}==> 5. Установка Logstash и Kibana...${NC}"
dpkg -i "$LS_DEB" "$KB_DEB"

# =============================================================================
# 6. Настройка Kibana
# =============================================================================
echo -e "${YELLOW}==> 6. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF

systemctl start kibana
systemctl enable kibana
echo -e "${GREEN}✓ Kibana запущена${NC}"

# =============================================================================
# 7. Настройка Logstash (приём логов от Filebeat на порту 5400)
# =============================================================================
echo -e "${YELLOW}==> 7. Настройка Logstash...${NC}"
mkdir -p /etc/logstash/conf.d

# Основной конфиг Logstash
cat > /etc/logstash/logstash.yml <<'EOF'
node.name: elk-logstash
path.config: /etc/logstash/conf.d
EOF

# Pipeline для обработки логов nginx
cat > /etc/logstash/conf.d/logstash-nginx-es.conf <<'EOF'
# Входные данные: слушаем порт 5400 от Filebeat
input {
    beats { port => 5400 }
}

# Фильтрация: парсинг Combined Log Format, преобразование типов, дата, User-Agent
filter {
    grok {
        match => [ "message" , "%{COMBINEDAPACHELOG}+%{GREEDYDATA:extra_fields}" ]
        overwrite => [ "message" ]
    }
    mutate {
        convert => ["response", "integer"]
        convert => ["bytes", "integer"]
        convert => ["responsetime", "float"]
    }
    date {
        match => [ "timestamp" , "dd/MMM/YYYY:HH:mm:ss Z" ]
        remove_field => [ "timestamp" ]
    }
    useragent { source => "agent" }
}

# Выход: в Elasticsearch и в консоль (для отладки)
output {
    elasticsearch {
        hosts => ["http://localhost:9200"]
        index => "weblogs-%{+YYYY.MM.dd}"
    }
    stdout { codec => rubydebug }
}
EOF

systemctl start logstash
systemctl enable logstash
echo -e "${GREEN}✓ Logstash запущен, слушает порт 5400${NC}"

# =============================================================================
# 8. Настройка UFW (межсетевой экран)
# =============================================================================
echo -e "${YELLOW}==> 8. Настройка UFW...${NC}"
apt install -y ufw

# Разрешаем SSH (обязательно, иначе потеряем доступ!)
ufw allow 22/tcp comment 'SSH'
# Kibana Web UI
ufw allow 5601/tcp comment 'Kibana UI'
# Приём логов от Filebeat
ufw allow 5400/tcp comment 'Logstash beats input'

# Включаем UFW без интерактивного подтверждения
echo "y" | ufw enable
ufw status verbose
echo -e "${GREEN}✓ UFW настроен и включён${NC}"

# =============================================================================
# 9. Финальная информация
# =============================================================================
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana:             ${BLUE}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API:  ${BLUE}http://192.168.50.48:9200${NC}"
echo -e "Logstash (Beats):   ${BLUE}порт 5400${NC}"
echo -e "\n${YELLOW}Проверка статуса сервисов:${NC}"
systemctl status elasticsearch --no-pager -l | head -3
systemctl status logstash --no-pager -l | head -3
systemctl status kibana --no-pager -l | head -3

echo -e "\n${YELLOW}Полезные команды:${NC}"
echo "  curl http://localhost:9200         # Проверка Elasticsearch"
echo "  ss -tlnp | grep 5400               # Проверка Logstash"
echo "  journalctl -u elasticsearch -f     # Логи Elasticsearch"
echo "  journalctl -u logstash -f          # Логи Logstash"
echo "  journalctl -u kibana -f            # Логи Kibana"
