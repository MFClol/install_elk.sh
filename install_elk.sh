#!/bin/bash
# =============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1
# IP сервера: 192.168.50.48
# Версия: 8.17.1
# Пакеты загружаются с Яндекс.Диска (ссылки clck.ru)
# =============================================================================

set -e  # Остановить скрипт при любой ошибке

# Отключаем интерактивные запросы apt
export DEBIAN_FRONTEND=noninteractive

# Цвета для красивого вывода
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack (8.17.1) на log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# =============================================================================
# 1. Установка JDK, wget, curl
# =============================================================================
echo -e "${YELLOW}==> 1. Установка JDK, wget, curl...${NC}"
apt update -qq
apt install -y -qq default-jdk wget curl

# =============================================================================
# 2. Скачивание пакетов с Яндекс.Диска
# =============================================================================
echo -e "${YELLOW}==> 2. Скачивание пакетов ELK с Яндекс.Диска...${NC}"
cd /tmp

echo -e "${YELLOW}--- Скачивание Elasticsearch ---${NC}"
wget -q --show-progress "https://clck.ru/3Tbvz5" -O elasticsearch.deb
if file elasticsearch.deb | grep -q "Debian binary package"; then
    echo -e "${GREEN}✓ Elasticsearch скачан успешно${NC}"
else
    echo -e "${RED}✗ Ошибка: скачанный файл не является deb-пакетом.${NC}"
    exit 1
fi

echo -e "${YELLOW}--- Скачивание Logstash ---${NC}"
wget -q --show-progress "https://clck.ru/3TbviL" -O logstash.deb
if file logstash.deb | grep -q "Debian binary package"; then
    echo -e "${GREEN}✓ Logstash скачан успешно${NC}"
else
    echo -e "${RED}✗ Ошибка при скачивании Logstash${NC}"
    exit 1
fi

echo -e "${YELLOW}--- Скачивание Kibana ---${NC}"
wget -q --show-progress "https://clck.ru/3Tbvws" -O kibana.deb
if file kibana.deb | grep -q "Debian binary package"; then
    echo -e "${GREEN}✓ Kibana скачана успешно${NC}"
else
    echo -e "${RED}✗ Ошибка при скачивании Kibana${NC}"
    exit 1
fi

# =============================================================================
# 3. Установка пакетов
# =============================================================================
echo -e "${YELLOW}==> 3. Установка пакетов...${NC}"
dpkg -i elasticsearch.deb logstash.deb kibana.deb

# =============================================================================
# 3.1. Полная очистка сгенерированных данных безопасности и прав
# =============================================================================
echo -e "${YELLOW}==> 3.1. Очистка сгенерированных данных безопасности...${NC}"

# Останавливаем сервис, если он запущен (на случай повторного запуска скрипта)
systemctl stop elasticsearch 2>/dev/null || true

# Удаляем сертификаты и keystore
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore

# Удаляем старые данные и логи Elasticsearch (чтобы избежать конфликтов)
rm -rf /var/lib/elasticsearch/*
rm -rf /var/log/elasticsearch/*

# Устанавливаем правильного владельца и права на /etc/elasticsearch
chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch

# Создаём пустой keystore от имени пользователя elasticsearch
sudo -u elasticsearch /usr/share/elasticsearch/bin/elasticsearch-keystore create 2>/dev/null || true

echo -e "${GREEN}✓ Ключи безопасности удалены, права настроены, keystore создан${NC}"

# =============================================================================
# 4. Настройка Elasticsearch (отключаем безопасность, слушаем все интерфейсы)
# =============================================================================
echo -e "${YELLOW}==> 4. Настройка Elasticsearch...${NC}"
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
cluster.name: elk-cluster
node.name: elk-node
network.host: 0.0.0.0
http.port: 9200

# Отключаем безопасность (HTTP, без TLS, без авторизации)
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

# Для одноузлового кластера
cluster.initial_master_nodes: ["elk-node"]
discovery.type: single-node
EOF

# Ещё раз убеждаемся, что права на конфиг корректны
chown elasticsearch:elasticsearch /etc/elasticsearch/elasticsearch.yml
chmod 660 /etc/elasticsearch/elasticsearch.yml

# Запускаем Elasticsearch
systemctl start elasticsearch
systemctl enable elasticsearch

# Ожидаем готовности (до 30 секунд)
echo -e "${YELLOW}Ожидание запуска Elasticsearch...${NC}"
for i in {1..15}; do
    if curl -s http://localhost:9200 > /dev/null 2>&1; then
        echo -e "${GREEN}✓ Elasticsearch запущен и отвечает на порту 9200${NC}"
        break
    fi
    sleep 2
done

# =============================================================================
# 5. Настройка Kibana
# =============================================================================
echo -e "${YELLOW}==> 5. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
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

# =============================================================================
# 7. Настройка UFW (межсетевой экран)
# =============================================================================
echo -e "${YELLOW}==> 7. Настройка UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'SSH'
ufw allow 5601/tcp comment 'Kibana UI'
ufw allow 5400/tcp comment 'Logstash beats input'
echo "y" | ufw enable
ufw status verbose
echo -e "${GREEN}✓ UFW настроен и включён${NC}"

# =============================================================================
# 8. Финальная проверка
# =============================================================================
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana: ${YELLOW}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API: ${YELLOW}http://192.168.50.48:9200${NC}"
echo -e "Logstash слушает порт: ${YELLOW}5400${NC}"
echo -e "\n${YELLOW}Проверка статуса:${NC}"
systemctl status elasticsearch --no-pager -l | head -5
systemctl status logstash --no-pager -l | head -5
systemctl status kibana --no-pager -l | head -5

echo -e "\n${YELLOW}Если возникли проблемы, посмотрите логи:${NC}"
echo "  journalctl -u elasticsearch -n 50"
echo "  journalctl -u logstash -n 50"
echo "  journalctl -u kibana -n 50"
