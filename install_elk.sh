#!/bin/bash
# ============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1
# IP: 192.168.50.48
# Версия: 8.17.1
# Пакеты должны лежать в /home/admin/
# =============================================================================

set -e  # Прерывать при ошибке
export DEBIAN_FRONTEND=noninteractive

# Цвета для вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

# Функция для вывода ошибок
die() {
    echo -e "${RED}ОШИБКА: $1${NC}" >&2
    exit 1
}

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack на сервер log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# -----------------------------------------------------------------------------
# 1. Установка JDK и вспомогательных утилит
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
echo -e "${GREEN}✓ Все deb-пакеты найдены в $DEB_DIR${NC}"

# -----------------------------------------------------------------------------
# 3. Полная переустановка Elasticsearch (чистая конфигурация)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 2. Чистая установка Elasticsearch...${NC}"
systemctl stop elasticsearch 2>/dev/null || true
dpkg --purge elasticsearch 2>/dev/null || true
rm -rf /etc/elasticsearch /var/lib/elasticsearch /var/log/elasticsearch /usr/share/elasticsearch
dpkg -i "$ES_DEB"

# Удаляем автоматически сгенерированные сертификаты и keystore
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore

# Создаём правильный конфиг (без cluster.initial_master_nodes, только single-node)
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

# Устанавливаем владельца и права
chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

# Создаём директории для логов и данных и даём права
mkdir -p /var/log/elasticsearch /var/lib/elasticsearch
chown -R elasticsearch:elasticsearch /var/log/elasticsearch /var/lib/elasticsearch
chmod 755 /var/log/elasticsearch /var/lib/elasticsearch

# Запускаем Elasticsearch
systemctl start elasticsearch
systemctl enable elasticsearch

# Ожидание готовности (до 30 секунд)
echo -e "${YELLOW}Ожидание запуска Elasticsearch...${NC}"
for i in {1..15}; do
    if curl -s http://localhost:9200 >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Elasticsearch запущен и отвечает${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 15 ]; then
        die "Elasticsearch не запустился за 30 секунд"
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
echo -e "${GREEN}✓ Kibana запущена${NC}"

# -----------------------------------------------------------------------------
# 6. Настройка Logstash (приём логов от Filebeat на порту 5400)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 5. Настройка Logstash...${NC}"
mkdir -p /etc/logstash/conf.d

cat > /etc/logstash/logstash.yml <<'EOF'
node.name: elk-logstash
path.config: /etc/logstash/conf.d
EOF

cat > /etc/logstash/conf.d/logstash-nginx-es.conf <<'EOF'
input {
    beats { port => 5400 }
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
    useragent { source => "agent" }
}
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

# -----------------------------------------------------------------------------
# 7. Настройка UFW (межсетевой экран)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 6. Настройка UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'SSH'
ufw allow 5601/tcp comment 'Kibana UI'
ufw allow 5400/tcp comment 'Logstash beats input'
echo "y" | ufw enable
ufw status verbose
echo -e "${GREEN}✓ UFW настроен и включён${NC}"

# -----------------------------------------------------------------------------
# 8. Итоговая информация
# -----------------------------------------------------------------------------
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana:             ${YELLOW}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API:  ${YELLOW}http://192.168.50.48:9200${NC}"
echo -e "Logstash порт:      ${YELLOW}5400${NC}"
echo -e "\n${YELLOW}Статус сервисов:${NC}"
systemctl status elasticsearch --no-pager -l | head -5
systemctl status logstash --no-pager -l | head -5
systemctl status kibana --no-pager -l | head -5
