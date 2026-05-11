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

# Функция для вывода ошибок и выхода
die() {
    echo -e "${RED}ОШИБКА: $1${NC}" >&2
    exit 1
}

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
wget -q --show-progress "https://clck.ru/3Tbvz5" -O elasticsearch.deb || die "Не удалось скачать elasticsearch.deb"
file elasticsearch.deb | grep -q "Debian binary package" || die "Скачанный файл elasticsearch.deb не является deb-пакетом"
echo -e "${GREEN}✓ Elasticsearch скачан успешно${NC}"

echo -e "${YELLOW}--- Скачивание Logstash ---${NC}"
wget -q --show-progress "https://clck.ru/3TbviL" -O logstash.deb || die "Не удалось скачать logstash.deb"
file logstash.deb | grep -q "Debian binary package" || die "Скачанный файл logstash.deb не является deb-пакетом"
echo -e "${GREEN}✓ Logstash скачан успешно${NC}"

echo -e "${YELLOW}--- Скачивание Kibana ---${NC}"
wget -q --show-progress "https://clck.ru/3Tbvws" -O kibana.deb || die "Не удалось скачать kibana.deb"
file kibana.deb | grep -q "Debian binary package" || die "Скачанный файл kibana.deb не является deb-пакетом"
echo -e "${GREEN}✓ Kibana скачана успешно${NC}"

# =============================================================================
# 3. Установка пакетов
# =============================================================================
echo -e "${YELLOW}==> 3. Установка пакетов...${NC}"
dpkg -i elasticsearch.deb logstash.deb kibana.deb

# =============================================================================
# 4. Полная переустановка и очистка конфигурации Elasticsearch
# =============================================================================
echo -e "${YELLOW}==> 4. Очистка сгенерированных данных безопасности и переустановка Elasticsearch...${NC}"

# Останавливаем сервис, если он запущен
systemctl stop elasticsearch 2>/dev/null || true

# Полностью удаляем каталог конфигурации Elasticsearch (он будет пересоздан при переустановке)
rm -rf /etc/elasticsearch

# Переустанавливаем пакет elasticsearch (чтобы получить чистые права и структуру)
apt install --reinstall -y elasticsearch

# Удаляем автоматически сгенерированные сертификаты и keystore (если они появились)
rm -rf /etc/elasticsearch/certs 2>/dev/null
rm -f /etc/elasticsearch/elasticsearch.keystore 2>/dev/null

# =============================================================================
# 5. Настройка Elasticsearch (отключаем безопасность, слушаем все интерфейсы)
# =============================================================================
echo -e "${YELLOW}==> 5. Настройка Elasticsearch...${NC}"
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

# Устанавливаем правильные права доступа
chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

# Удаляем старые данные и логи Elasticsearch (чтобы избежать конфликтов)
rm -rf /var/lib/elasticsearch/*
rm -rf /var/log/elasticsearch/*

# =============================================================================
# 6. Запуск Elasticsearch и проверка
# =============================================================================
echo -e "${YELLOW}==> 6. Запуск Elasticsearch...${NC}"
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
    if [ $i -eq 15 ]; then
        die "Elasticsearch не запустился за 30 секунд. Проверьте логи: journalctl -u elasticsearch"
    fi
done

# =============================================================================
# 7. Настройка Kibana
# =============================================================================
echo -e "${YELLOW}==> 7. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
server.port: 5601
server.host: "0.0.0.0"
elasticsearch.hosts: ["http://localhost:9200"]
EOF

systemctl start kibana
systemctl enable kibana
echo -e "${GREEN}✓ Kibana запущена${NC}"

# =============================================================================
# 8. Настройка Logstash (приём логов от Filebeat на порту 5400)
# =============================================================================
echo -e "${YELLOW}==> 8. Настройка Logstash...${NC}"
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
# 9. Настройка UFW (межсетевой экран)
# =============================================================================
echo -e "${YELLOW}==> 9. Настройка UFW...${NC}"
apt install -y ufw
ufw allow 22/tcp comment 'SSH'
ufw allow 5601/tcp comment 'Kibana UI'
ufw allow 5400/tcp comment 'Logstash beats input'
echo "y" | ufw enable
ufw status verbose
echo -e "${GREEN}✓ UFW настроен и включён${NC}"

# =============================================================================
# 10. Финальная проверка и информация
# =============================================================================
echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack завершена успешно! ===${NC}"
echo -e "${GREEN}============================================${NC}"
echo -e "Kibana: ${YELLOW}http://192.168.50.48:5601${NC}"
echo -e "Elasticsearch API: ${YELLOW}http://192.168.50.48:9200${NC}"
echo -e "Logstash слушает порт: ${YELLOW}5400${NC}"
echo -e "\n${YELLOW}Проверка статуса сервисов:${NC}"
systemctl status elasticsearch --no-pager -l | head -5
systemctl status logstash --no-pager -l | head -5
systemctl status kibana --no-pager -l | head -5

echo -e "\n${YELLOW}Если возникли проблемы, посмотрите логи:${NC}"
echo "  journalctl -u elasticsearch -n 50"
echo "  journalctl -u logstash -n 50"
echo "  journalctl -u kibana -n 50"
