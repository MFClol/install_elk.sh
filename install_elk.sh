#!/bin/bash
# =============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1
# IP сервера: 192.168.50.48
# Версия: 8.17.1
# Используется Яндекс зеркало (доступно из РФ)
# =============================================================================

set -e  # Остановить скрипт при любой ошибке

# Отключаем интерактивные запросы apt
export DEBIAN_FRONTEND=noninteractive

# Цвета для вывода (опционально, для красоты)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack (8.17.1) на log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# =============================================================================
# 1. Обновление системы и установка JDK (Java Development Kit)
# =============================================================================
echo -e "${YELLOW}==> 1. Установка JDK, wget, curl...${NC}"
apt update -qq
apt install -y -qq default-jdk wget curl

# =============================================================================
# 2. Скачивание пакетов Elasticsearch, Logstash, Kibana с Яндекс зеркала
# =============================================================================
echo -e "${YELLOW}==> 2. Скачивание пакетов ELK...${NC}"
cd /tmp
wget -q --show-progress https://mirror.yandex.ru/mirrors/elastic/8.17.1/elasticsearch-8.17.1-amd64.deb
wget -q --show-progress https://mirror.yandex.ru/mirrors/elastic/8.17.1/logstash-8.17.1-amd64.deb
wget -q --show-progress https://mirror.yandex.ru/mirrors/elastic/8.17.1/kibana-8.17.1-amd64.deb

# =============================================================================
# 3. Установка пакетов
# =============================================================================
echo -e "${YELLOW}==> 3. Установка пакетов...${NC}"
dpkg -i elasticsearch-8.17.1-amd64.deb
dpkg -i logstash-8.17.1-amd64.deb
dpkg -i kibana-8.17.1-amd64.deb

# =============================================================================
# 4. Настройка Elasticsearch
# =============================================================================
echo -e "${YELLOW}==> 4. Настройка Elasticsearch...${NC}"
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
# --------------------------- Elasticsearch Configuration ---------------------------
cluster.name: elk-cluster
node.name: elk-node
network.host: 0.0.0.0
http.port: 9200

# Отключаем безопасность (HTTP, без TLS, без авторизации) – согласно заданию
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

# Для одноузлового кластера
cluster.initial_master_nodes: ["elk-node"]
discovery.type: single-node
EOF

systemctl start elasticsearch
systemctl enable elasticsearch
echo -e "${GREEN}✓ Elasticsearch запущен${NC}"

# =============================================================================
# 5. Настройка Kibana
# =============================================================================
echo -e "${YELLOW}==> 5. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
# --------------------------- Kibana Configuration ---------------------------
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF

systemctl start kibana
systemctl enable kibana
echo -e "${GREEN}✓ Kibana запущена${NC}"

# =============================================================================
# 6. Настройка Logstash (приём логов от Filebeat на порту 5400)
# =============================================================================
echo -e "${YELLOW}==> 6. Настройка Logstash...${NC}"
mkdir -p /etc/logstash/conf.d

# Основной конфиг Logstash
cat > /etc/logstash/logstash.yml <<'EOF'
node.name: elk-logstash
path.config: /etc/logstash/conf.d
EOF

# Pipeline для обработки логов nginx
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
    useragent {
        source => "agent"
    }
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

# =============================================================================
# 7. Настройка UFW (межсетевой экран) – открываем только необходимые порты
# =============================================================================
echo -e "${YELLOW}==> 7. Настройка UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'SSH'
ufw allow 5601/tcp comment 'Kibana UI'
ufw allow 5400/tcp comment 'Logstash beats input'
echo "y" | ufw enable
ufw status verbose

# =============================================================================
# 8. Финальная проверка и информация
# =============================================================================
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana доступна по адресу: ${YELLOW}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API: ${YELLOW}http://192.168.50.48:9200${NC}"
echo -e "Logstash слушает порт: ${YELLOW}5400${NC} (для приёма логов от Filebeat)"
echo -e "\n${YELLOW}Проверка статуса сервисов:${NC}"
systemctl status elasticsearch --no-pager -l | head -5
systemctl status logstash --no-pager -l | head -5
systemctl status kibana --no-pager -l | head -5
