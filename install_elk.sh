#!/bin/bash
# =============================================================================
# Установка ELK Stack (Elasticsearch, Logstash, Kibana) на сервер log1
# IP сервера: 192.168.50.48
# Версия: 8.17.1
# Пакеты загружаются с Яндекс.Диска (ссылки предоставлены пользователем)
# =============================================================================

set -e  # Остановить скрипт при любой ошибке

# Отключаем интерактивные запросы apt (чтобы установка проходила без вопросов)
export DEBIAN_FRONTEND=noninteractive

# Цвета для красивого вывода в консоль (опционально)
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}============================================${NC}"
echo -e "${GREEN}=== Установка ELK Stack (8.17.1) на log1 ===${NC}"
echo -e "${GREEN}============================================${NC}"

# =============================================================================
# 1. Обновление системы и установка JDK (Java Development Kit)
# =============================================================================
# Elasticsearch и Logstash требуют Java. Устанавливаем OpenJDK.
echo -e "${YELLOW}==> 1. Установка JDK, wget, curl...${NC}"
apt update -qq
apt install -y -qq default-jdk wget curl

# =============================================================================
# 2. Скачивание пакетов Elasticsearch, Logstash, Kibana с Яндекс.Диска
# =============================================================================
# Используем прямые ссылки, предоставленные пользователем.
# Внимание: ссылки ведут на файлы, которые необходимо скачать.
echo -e "${YELLOW}==> 2. Скачивание пакетов ELK с Яндекс.Диска...${NC}"
cd /tmp

# Скачиваем Elasticsearch
echo -e "${YELLOW}--- Скачивание Elasticsearch ---${NC}"
wget -q --show-progress "https://disk.yandex.ru/d/-BkYBKY8cG2qPA" -O elasticsearch.deb
# Проверяем, что файл действительно скачался (не страница с подтверждением)
if file elasticsearch.deb | grep -q "Debian binary package"; then
    echo -e "${GREEN}✓ Elasticsearch скачан успешно${NC}"
else
    echo -e "${RED}✗ Ошибка: скачанный файл не является deb-пакетом. Возможно, требуется подтверждение скачивания с Яндекс.Диска.${NC}"
    echo -e "${YELLOW}Попробуйте скачать файлы вручную и положить в /tmp/ с именами: elasticsearch.deb, logstash.deb, kibana.deb${NC}"
    exit 1
fi

# Скачиваем Logstash
echo -e "${YELLOW}--- Скачивание Logstash ---${NC}"
wget -q --show-progress "https://disk.yandex.ru/d/Spe6wIE9PLTeGA" -O logstash.deb
if file logstash.deb | grep -q "Debian binary package"; then
    echo -e "${GREEN}✓ Logstash скачан успешно${NC}"
else
    echo -e "${RED}✗ Ошибка при скачивании Logstash${NC}"
    exit 1
fi

# Скачиваем Kibana
echo -e "${YELLOW}--- Скачивание Kibana ---${NC}"
wget -q --show-progress "https://disk.yandex.ru/d/FpR7HCLmPunDfA" -O kibana.deb
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
dpkg -i elasticsearch.deb
dpkg -i logstash.deb
dpkg -i kibana.deb

# =============================================================================
# 4. Настройка Elasticsearch
# =============================================================================
echo -e "${YELLOW}==> 4. Настройка Elasticsearch...${NC}"
cat > /etc/elasticsearch/elasticsearch.yml <<'EOF'
# --------------------------- Elasticsearch Configuration ---------------------------
# Имя кластера (можете изменить)
cluster.name: elk-cluster
# Имя текущего узла
node.name: elk-node
# Слушаем все сетевые интерфейсы (чтобы был доступ с других серверов)
network.host: 0.0.0.0
# Порт для HTTP API
http.port: 9200

# Отключаем безопасность (HTTP, без TLS, без авторизации) – согласно заданию
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

# Для одноузлового кластера (без поиска других узлов)
cluster.initial_master_nodes: ["elk-node"]
discovery.type: single-node
EOF

# Запускаем Elasticsearch и добавляем в автозагрузку
systemctl start elasticsearch
systemctl enable elasticsearch
echo -e "${GREEN}✓ Elasticsearch запущен${NC}"

# Небольшая пауза, чтобы Elasticsearch успел стартовать
sleep 10

# =============================================================================
# 5. Настройка Kibana
# =============================================================================
echo -e "${YELLOW}==> 5. Настройка Kibana...${NC}"
cat > /etc/kibana/kibana.yml <<'EOF'
# --------------------------- Kibana Configuration ---------------------------
# Порт веб-интерфейса
server.port: 5601
# Доступно с любого IP (для подключения из браузера)
server.host: "0.0.0.0"
# Адрес Elasticsearch (локальный, через HTTP)
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

# Основной конфиг Logstash (указываем директорию с pipelines)
cat > /etc/logstash/logstash.yml <<'EOF'
node.name: elk-logstash
path.config: /etc/logstash/conf.d
EOF

# Создаём pipeline для обработки логов nginx
cat > /etc/logstash/conf.d/logstash-nginx-es.conf <<'EOF'
# Входные данные: слушаем порт 5400 для подключений от Filebeat
input {
    beats {
        port => 5400
    }
}

# Фильтры: парсинг логов nginx, преобразование типов, извлечение даты, User-Agent
filter {
    # Разбор строки в формате Combined Log Format (стандарт nginx)
    grok {
        match => [ "message" , "%{COMBINEDAPACHELOG}+%{GREEDYDATA:extra_fields}" ]
        overwrite => [ "message" ]
    }
    # Преобразование полей в числа (для корректной визуализации и агрегаций)
    mutate {
        convert => ["response", "integer"]
        convert => ["bytes", "integer"]
        convert => ["responsetime", "float"]
    }
    # Извлечение временной метки из поля timestamp (формат: 11/May/2026:14:48:22 +0000)
    date {
        match => [ "timestamp" , "dd/MMM/YYYY:HH:mm:ss Z" ]
        remove_field => [ "timestamp" ]
    }
    # Парсинг User-Agent (браузер, ОС, устройство)
    useragent {
        source => "agent"
    }
}

# Выходные данные: отправка в Elasticsearch и вывод в консоль (для отладки)
output {
    elasticsearch {
        hosts => ["http://localhost:9200"]
        index => "weblogs-%{+YYYY.MM.dd}"   # Индекс с динамическим именем по дате
    }
    stdout { codec => rubydebug }   # Для отладки (можно закомментировать после проверки)
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

# Разрешаем SSH (обязательно, иначе потеряем доступ)
ufw allow 22/tcp comment 'SSH'
# Разрешаем доступ к Kibana из браузера
ufw allow 5601/tcp comment 'Kibana UI'
# Разрешаем доступ к Logstash от Filebeat (с сервера nginx)
ufw allow 5400/tcp comment 'Logstash beats input'

# Включаем UFW (автоматически подтверждаем)
echo "y" | ufw enable

# Показываем статус правил
ufw status verbose
echo -e "${GREEN}✓ UFW настроен и включён${NC}"

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

echo -e "\n${YELLOW}Если сервисы не запустились, посмотрите логи:${NC}"
echo "  journalctl -u elasticsearch -n 50"
echo "  journalctl -u logstash -n 50"
echo "  journalctl -u kibana -n 50"
