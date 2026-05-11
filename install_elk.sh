#!/bin/bash
# Установка ELK Stack на сервер log1 (192.168.50.48)
# ----------------------------------------------------
# Скрипт должен выполняться от root или через sudo.

set -e  # Остановка при любой ошибке — если что-то пойдет не так, скрипт прервется.

export DEBIAN_FRONTEND=noninteractive  # Отключаем интерактивные запросы (например, при установке пакетов)

# ------- 1. Обновление системы и установка JDK -------
apt update
apt install -y default-jdk wget curl
# Java (JDK) требуется для работы Elasticsearch и Logstash.
# wget и curl нужны для скачивания пакетов и проверки соединений.

# ------- 2. Скачивание пакетов с Яндекс зеркала -------
cd /tmp
# Используем зеркало Яндекса, потому что официальный репозиторий Elastic часто блокируется из РФ (403 Forbidden).
wget https://mirror.yandex.ru/mirrors/elastic/8.17.1/elasticsearch-8.17.1-amd64.deb
wget https://mirror.yandex.ru/mirrors/elastic/8.17.1/logstash-8.17.1-amd64.deb
wget https://mirror.yandex.ru/mirrors/elastic/8.17.1/kibana-8.17.1-amd64.deb

# ------- 3. Установка пакетов -------
dpkg -i elasticsearch-8.17.1-amd64.deb
dpkg -i logstash-8.17.1-amd64.deb
dpkg -i kibana-8.17.1-amd64.deb
# dpkg -i устанавливает .deb пакеты. При необходимости могут быть предупреждения о зависимостях,
# но все основные зависимости уже удовлетворены установкой JDK.

# ------- 4. Настройка Elasticsearch -------
cat > /etc/elasticsearch/elasticsearch.yml <<EOF
cluster.name: elk-cluster          # Имя кластера (может быть любым)
node.name: elk-node                # Имя этого узла
network.host: 0.0.0.0              # Слушаем все сетевые интерфейсы (чтобы был доступ извне)
http.port: 9200                    # Стандартный порт Elasticsearch REST API

# Отключаем безопасность (согласно заданию – HTTP, без TLS, без авторизации)
xpack.security.enabled: false
xpack.security.enrollment.enabled: false
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false

# Настройки для одноузлового кластера (без discovery)
cluster.initial_master_nodes: ["elk-node"]
discovery.type: single-node
EOF

# Запускаем Elasticsearch и добавляем в автозагрузку
systemctl start elasticsearch
systemctl enable elasticsearch

# ------- 5. Настройка Kibana -------
cat > /etc/kibana/kibana.yml <<EOF
server.port: 5601                  # Порт веб-интерфейса
server.host: "0.0.0.0"             # Доступно с любого IP (для подключения из браузера)
elasticsearch.hosts: ["http://localhost:9200"]  # Адрес локального Elasticsearch (HTTP)
EOF

systemctl start kibana
systemctl enable kibana

# ------- 6. Настройка Logstash -------
# Создаём директорию для конфигураций pipelines
mkdir -p /etc/logstash/conf.d

# Основной конфиг Logstash (указываем где искать pipelines)
cat > /etc/logstash/logstash.yml <<EOF
node.name: elk-logstash
path.config: /etc/logstash/conf.d   # Папка, где лежат .conf файлы pipeline'ов
EOF

# Создаём pipeline для обработки логов nginx
cat > /etc/logstash/conf.d/logstash-nginx-es.conf <<EOF
input {
    beats {
        port => 5400                # Порт, на котором Logstash слушает соединения от Filebeat
    }
}
filter {
    # Парсим строку лога в формате Combined (стандартный формат nginx)
    grok {
        match => [ "message" , "%{COMBINEDAPACHELOG}+%{GREEDYDATA:extra_fields}" ]
        overwrite => [ "message" ]
    }
    # Преобразуем некоторые поля в числа (для корректной визуализации в Kibana)
    mutate {
        convert => ["response", "integer"]
        convert => ["bytes", "integer"]
        convert => ["responsetime", "float"]
    }
    # Извлекаем дату из поля timestamp (день/мес/год:час:мин:сек таймзона)
    date {
        match => [ "timestamp" , "dd/MMM/YYYY:HH:mm:ss Z" ]
        remove_field => [ "timestamp" ]
    }
    # Обогащаем данные информацией о браузере/ОС из User-Agent
    useragent {
        source => "agent"
    }
}
output {
    # Отправляем обработанные события в Elasticsearch
    elasticsearch {
        hosts => ["http://localhost:9200"]
        index => "weblogs-%{+YYYY.MM.dd}"   # Индекс с динамическим именем по дате
    }
    # Дублируем вывод в консоль (удобно для отладки, можно удалить после проверки)
    stdout { codec => rubydebug }
}
EOF

# Запускаем Logstash
systemctl start logstash
systemctl enable logstash

# ------- 7. Настройка UFW (межсетевой экран) -------
apt install -y ufw
# Открываем порт SSH – обязательно, иначе потеряем доступ к серверу
ufw allow 22/tcp
# Kibana (веб-интерфейс)
ufw allow 5601/tcp
# Logstash (приём логов от Filebeat)
ufw allow 5400/tcp
# Включаем UFW (автоматически подтверждаем)
echo "y" | ufw enable

# ------- 8. Финальное сообщение -------
echo "ELK установлен. Kibana: http://192.168.50.48:5601"
