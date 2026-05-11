#!/bin/bash
# =============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1 (192.168.50.48)
# Версия: 8.17.1
# Использует локальные deb-файлы из /home/admin/
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
echo -e "${GREEN}=== Установка ELK Stack (8.17.1) на log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# -----------------------------------------------------------------------------
# 1. Установка JDK
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 1. Установка JDK, wget, curl...${NC}"
apt update -qq
apt install -y -qq default-jdk wget curl

# -----------------------------------------------------------------------------
# 2. Проверка локальных deb-файлов
# -----------------------------------------------------------------------------
DEB_DIR="/home/admin"
ES_DEB="$DEB_DIR/elasticsearch_8.17.1_amd64-224190-a8d54b.deb"
LS_DEB="$DEB_DIR/logstash_8.17.1_amd64-224190-b63239.deb"
KB_DEB="$DEB_DIR/kibana_8.17.1_amd64-224190-9c79ef.deb"

for f in "$ES_DEB" "$LS_DEB" "$KB_DEB"; do
    if [ ! -f "$f" ]; then
        die "Не найден файл: $f"
    fi
done
echo -e "${GREEN}✓ Все deb-пакеты найдены${NC}"

# -----------------------------------------------------------------------------
# 3. Установка пакетов (без переустановки)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 2. Установка пакетов ELK...${NC}"
dpkg -i "$ES_DEB" "$LS_DEB" "$KB_DEB"

# -----------------------------------------------------------------------------
# 4. Очистка конфигурации Elasticsearch (без вызова apt)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 3. Очистка сгенерированных данных безопасности...${NC}"
systemctl stop elasticsearch 2>/dev/null || true

# Удаляем старый каталог конфигурации и создаём заново
rm -rf /etc/elasticsearch
mkdir -p /etc/elasticsearch

# Удаляем keystore и сертификаты, если остались где-то ещё
rm -f /etc/elasticsearch/elasticsearch.keystore 2>/dev/null
rm -rf /etc/elasticsearch/certs 2>/dev/null

# Очищаем данные и логи
rm -rf /var/lib/elasticsearch/*
rm -rf /var/log/elasticsearch/*

# -----------------------------------------------------------------------------
# 5. Настройка Elasticsearch (безопасность отключена)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 4. Настройка Elasticsearch...${NC}"
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: elk-cluster
node.name: elk-node
network.host: 0.0.0.0
http.port: 9200
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
cluster.initial_master_nodes: ["elk-node"]
discovery.type: single-node
EOF

# Права доступа
chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

# -----------------------------------------------------------------------------
# 6. Запуск Elasticsearch
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 5. Запуск Elasticsearch...${NC}"
systemctl start elasticsearch
systemctl enable elasticsearch

echo -e "${YELLOW}Ожидание запуска Elasticsearch (до 30 сек)...${NC}"
for i in {1..15}; do
    if curl -s http://localhost:9200 > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Elasticsearch запущен${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 15 ]; then
        echo -e "${RED}⚠️  Elasticsearch не запустился. Проверьте: journalctl -u elasticsearch${NC}"
    fi
done

# -----------------------------------------------------------------------------
# 7. Настройка Kibana
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 6. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF

systemctl start kibana
systemctl enable kibana
echo -e "${GREEN}✓ Kibana запущена${NC}"

# -----------------------------------------------------------------------------
# 8. Настройка Logstash
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 7. Настройка Logstash...${NC}"
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
# 9. UFW
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 8. Настройка UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'SSH'
ufw allow 5601/tcp comment 'Kibana UI'
ufw allow 5400/tcp comment 'Logstash beats input'
echo "y" | ufw enable
ufw status verbose

# -----------------------------------------------------------------------------
# 10. Итог
# -----------------------------------------------------------------------------
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana: ${YELLOW}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API: ${YELLOW}http://192.168.50.48:9200${NC}"
echo -e "Logstash port: ${YELLOW}5400${NC}"
