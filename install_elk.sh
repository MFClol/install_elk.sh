#!/bin/bash
# ============================================
# Скрипт установки ELK Stack (Elasticsearch, Logstash, Kibana)
# Сервер: 192.168.50.186
# Версия: 8.17.1
# ============================================

set -e  # Остановка при любой ошибке

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack на сервер 192.168.50.186 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# === 1. Установка JDK ===
echo -e "${YELLOW}=== 1. Установка JDK ===${NC}"
apt update
apt install -y default-jdk wget curl

# === 2. Скачивание и установка пакетов ===
echo -e "${YELLOW}=== 2. Скачивание и установка Elasticsearch, Logstash, Kibana ===${NC}"
cd /tmp
wget -q --show-progress https://artifacts.elastic.co/downloads/elasticsearch/elasticsearch-8.17.1-amd64.deb
wget -q --show-progress https://artifacts.elastic.co/downloads/logstash/logstash-8.17.1-amd64.deb
wget -q --show-progress https://artifacts.elastic.co/downloads/kibana/kibana-8.17.1-amd64.deb

dpkg -i elasticsearch-8.17.1-amd64.deb
dpkg -i logstash-8.17.1-amd64.deb
dpkg -i kibana-8.17.1-amd64.deb

# === 3. Настройка Elasticsearch ===
echo -e "${YELLOW}=== 3. Настройка Elasticsearch ===${NC}"
cat > /etc/elasticsearch/elasticsearch.yml << 'EOF'
# ======================== Elasticsearch Configuration ========================
cluster.name: elk-cluster
node.name: elk-node
path.data: /var/lib/elasticsearch
path.logs: /var/log/elasticsearch
network.host: 0.0.0.0
http.port: 9200

# Отключение безопасности (согласно заданию - HTTP, без TLS)
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

# Начальный мастер-узел
cluster.initial_master_nodes: ["elk-node"]
EOF

# Запуск Elasticsearch
systemctl daemon-reload
systemctl start elasticsearch
systemctl enable elasticsearch

# Ожидание готовности Elasticsearch
echo -e "${YELLOW}Ожидание запуска Elasticsearch...${NC}"
sleep 10

# Проверка Elasticsearch
if curl -s http://localhost:9200 > /dev/null; then
    echo -e "${GREEN}✓ Elasticsearch успешно запущен${NC}"
else
    echo -e "${RED}✗ Ошибка запуска Elasticsearch${NC}"
    exit 1
fi

# === 4. Настройка Kibana ===
echo -e "${YELLOW}=== 4. Настройка Kibana ===${NC}"
cat > /etc/kibana/kibana.yml << 'EOF'
# ======================== Kibana Configuration ========================
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF

# Запуск Kibana
systemctl start kibana
systemctl enable kibana

# === 5. Настройка Logstash ===
echo -e "${YELLOW}=== 5. Настройка Logstash ===${NC}"

# Основной конфиг Logstash
cat > /etc/logstash/logstash.yml << 'EOF'
# ======================== Logstash Configuration ========================
node.name: elk-logstash
path.data: /var/lib/logstash
path.config: /etc/logstash/conf.d
pipeline.workers: 2
pipeline.batch.size: 125
pipeline.batch.delay: 50
log.level: info
path.logs: /var/log/logstash
config.test_and_exit: false
config.reload.automatic: false
EOF

# Создание папки для конфигов
mkdir -p /etc/logstash/conf.d

# Конфиг пайплайна для приёма логов от Filebeat
cat > /etc/logstash/conf.d/logstash-nginx-es.conf << 'EOF'
# ======================== Logstash Pipeline for Nginx Logs ========================
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
        document_type => "nginx_logs"
    }
    stdout { codec => rubydebug }
}
EOF

# Запуск Logstash
systemctl start logstash
systemctl enable logstash

# === 6. Настройка UFW (межсетевой экран) ===
echo -e "${YELLOW}=== 6. Настройка UFW ===${NC}"
apt install -y ufw

# SSH (обязательно, чтобы не потерять доступ)
ufw allow 22/tcp comment 'SSH'

# Kibana (веб-интерфейс)
ufw allow 5601/tcp comment 'Kibana Web UI'

# Logstash (приём логов от Filebeat)
ufw allow 5400/tcp comment 'Logstash Beats input'

# Elasticsearch (опционально - для отладки, можно закомментировать)
ufw allow from 192.168.50.0/24 to any port 9200 proto tcp comment 'Elasticsearch local network'

# Включаем UFW
echo "y" | ufw enable

# Показываем статус правил
ufw status verbose

# === 7. Проверка сервисов ===
echo -e "${YELLOW}=== 7. Проверка сервисов ===${NC}"

echo -e "\n${GREEN}--- Elasticsearch ---${NC}"
systemctl status elasticsearch --no-pager -l

echo -e "\n${GREEN}--- Logstash ---${NC}"
systemctl status logstash --no-pager -l

echo -e "\n${GREEN}--- Kibana ---${NC}"
systemctl status kibana --no-pager -l

# === 8. Проверка открытых портов ===
echo -e "${YELLOW}=== 8. Проверка открытых портов ===${NC}"
ss -tlnp | grep -E ':(9200|5400|5601)' || echo -e "${RED}Порты не найдены, проверьте сервисы${NC}"

# === 9. Тест Elasticsearch ===
echo -e "${YELLOW}=== 9. Тест Elasticsearch ===${NC}"
curl -s http://localhost:9200 | head -5

# === Итог ===
echo -e "\n${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana доступна по адресу: ${YELLOW}http://192.168.50.186:5601${NC}"
echo -e "Logstash слушает порт: ${YELLOW}5400${NC} (для приёма логов от Filebeat)"
echo -e "Elasticsearch доступен по адресу: ${YELLOW}http://192.168.50.186:9200${NC}"
echo -e "\n${YELLOW}Проверка индексов:${NC}"
echo -e "  curl http://localhost:9200/_cat/indices"
echo -e "\n${YELLOW}Просмотр логов Logstash:${NC}"
echo -e "  journalctl -u logstash -f"