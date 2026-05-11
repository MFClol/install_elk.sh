#!/bin/bash
# =============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1 (192.168.50.48)
# Версия: 8.17.1
# Пакеты берутся из /home/admin/
# =============================================================================

set -e  # Остановка при любой ошибке
export DEBIAN_FRONTEND=noninteractive

# Цвета
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

die() {
    echo -e "${RED}ОШИБКА: $1${NC}" >&2
    exit 1
}

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack на сервер log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# -----------------------------------------------------------------------------
# 1. Установка JDK и утилит
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 1. Установка JDK, wget, curl...${NC}"
apt update -qq
apt install -y -qq default-jdk wget curl

# -----------------------------------------------------------------------------
# 2. Проверка наличия deb-пакетов
# -----------------------------------------------------------------------------
DEB_DIR="/home/admin"
ES_DEB="$DEB_DIR/elasticsearch_8.17.1_amd64-224190-a8d54b.deb"
LS_DEB="$DEB_DIR/logstash_8.17.1_amd64-224190-b63239.deb"
KB_DEB="$DEB_DIR/kibana_8.17.1_amd64-224190-9c79ef.deb"

for f in "$ES_DEB" "$LS_DEB" "$KB_DEB"; do
    [ -f "$f" ] || die "Не найден файл: $f"
done
echo -e "${GREEN}✓ Все deb-пакеты найдены${NC}"

# -----------------------------------------------------------------------------
# 3. Чистая установка Elasticsearch (purge + заново)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 2. Чистая установка Elasticsearch...${NC}"
systemctl stop elasticsearch 2>/dev/null || true
dpkg --purge elasticsearch 2>/dev/null || true
rm -rf /etc/elasticsearch /var/lib/elasticsearch /var/log/elasticsearch /usr/share/elasticsearch
dpkg -i "$ES_DEB"

# Удаляем автоматически сгенерированные сертификаты и keystore
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore

# Настройка Elasticsearch (безопасность отключена, пути логов/данных)
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: elk-cluster
node.name: elk-node
network.host: 0.0.0.0
http.port: 9200
path.logs: /var/log/elasticsearch
path.data: /var/lib/elasticsearch
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
discovery.type: single-node
EOF

# Права на конфиг
chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

# Создаём каталоги для логов и данных Elasticsearch
mkdir -p /var/log/elasticsearch /var/lib/elasticsearch
chown -R elasticsearch:elasticsearch /var/log/elasticsearch /var/lib/elasticsearch
chmod 755 /var/log/elasticsearch /var/lib/elasticsearch

# Запуск Elasticsearch
systemctl start elasticsearch
systemctl enable elasticsearch

# Ожидание готовности
echo -e "${YELLOW}Ожидание запуска Elasticsearch (до 30 сек)...${NC}"
for i in {1..15}; do
    if curl -s http://localhost:9200 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Elasticsearch запущен${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 15 ]; then
        die "Elasticsearch не запустился"
    fi
done

# -----------------------------------------------------------------------------
# 4. Установка Logstash и Kibana
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 3. Установка Logstash и Kibana...${NC}"
dpkg -i "$LS_DEB" "$KB_DEB"

# -----------------------------------------------------------------------------
# 5. Настройка Kibana
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 4. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF

systemctl start kibana
systemctl enable kibana

# -----------------------------------------------------------------------------
# 6. Настройка Logstash (исправлены права и убран фильтр useragent)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 5. Настройка Logstash...${NC}"

# Создаём каталоги для данных и логов Logstash (чтобы избежать ошибок прав)
mkdir -p /usr/share/logstash/data /usr/share/logstash/logs
chown -R logstash:logstash /usr/share/logstash/data /usr/share/logstash/logs
chmod 755 /usr/share/logstash/data /usr/share/logstash/logs

mkdir -p /etc/logstash/conf.d

# Основной конфиг Logstash
cat > /etc/logstash/logstash.yml <<'EOF'
node.name: elk-logstash
path.config: /etc/logstash/conf.d
path.data: /usr/share/logstash/data
path.logs: /usr/share/logstash/logs
EOF

# Pipeline для приёма логов nginx (без useragent, чтобы избежать ошибок)
cat > /etc/logstash/conf.d/logstash-nginx-es.conf <<'EOF'
input {
    beats {
        port => 5400
    }
}
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
    # Фильтр useragent отключён, т.к. вызывает ошибки при наличии структурированного поля agent
    # useragent { source => "agent" }
}
output {
    elasticsearch {
        hosts => ["http://localhost:9200"]
        index => "weblogs-%{+YYYY.MM.dd}"
    }
    stdout { codec => rubydebug }
}
EOF

# Запуск Logstash
systemctl start logstash
systemctl enable logstash

# -----------------------------------------------------------------------------
# 7. Настройка UFW
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 6. Настройка UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'SSH'
ufw allow 5601/tcp comment 'Kibana UI'
ufw allow 5400/tcp comment 'Logstash beats input'
echo "y" | ufw enable
ufw status verbose

# -----------------------------------------------------------------------------
# 8. Финальная информация
# -----------------------------------------------------------------------------
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana:             ${YELLOW}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API:  ${YELLOW}http://192.168.50.48:9200${NC}"
echo -e "Logstash порт:      ${YELLOW}5400${NC} (приём логов от Filebeat)"
echo -e "\n${YELLOW}Проверка статуса:${NC}"
systemctl status elasticsearch --no-pager -l | head -5
systemctl status logstash --no-pager -l | head -5
systemctl status kibana --no-pager -l | head -5
