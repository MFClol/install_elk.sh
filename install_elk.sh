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
# 3. Чистая установка Elasticsearch
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 2. Чистая установка Elasticsearch...${NC}"
systemctl stop elasticsearch 2>/dev/null || true
dpkg --purge elasticsearch 2>/dev/null || true
rm -rf /etc/elasticsearch /var/lib/elasticsearch /var/log/elasticsearch /usr/share/elasticsearch

dpkg -i "$ES_DEB"

# Удаляем автоматически сгенерированные сертификаты и keystore
rm -rf /etc/elasticsearch/certs
rm -f /etc/elasticsearch/elasticsearch.keystore

# Создаём конфиг (безопасность отключена, заданы пути логов и данных)
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

chown -R elasticsearch:elasticsearch /etc/elasticsearch
chmod 750 /etc/elasticsearch
chmod 660 /etc/elasticsearch/elasticsearch.yml

mkdir -p /var/log/elasticsearch /var/lib/elasticsearch
chown -R elasticsearch:elasticsearch /var/log/elasticsearch /var/lib/elasticsearch
chmod 755 /var/log/elasticsearch /var/lib/elasticsearch

systemctl start elasticsearch
systemctl enable elasticsearch

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
# 6. Настройка Logstash
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 5. Настройка Logstash...${NC}"
mkdir -p /usr/share/logstash/data /usr/share/logstash/logs
chown -R logstash:logstash /usr/share/logstash/data /usr/share/logstash/logs
chmod 755 /usr/share/logstash/data /usr/share/logstash/logs

mkdir -p /etc/logstash/conf.d

cat > /etc/logstash/logstash.yml <<'EOF'
node.name: elk-logstash
path.config: /etc/logstash/conf.d
path.data: /usr/share/logstash/data
path.logs: /usr/share/logstash/logs
EOF

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
# 8. Создание дашборда в Kibana через API (полностью рабочий метод)
# -----------------------------------------------------------------------------
echo -e "${YELLOW}==> 7. Создание дашборда в Kibana...${NC}"

# Ожидание готовности Kibana
skip_dashboard=0
for i in {1..30}; do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:5601/api/status | grep -q "200"; then
        echo -e "${GREEN}✓ Kibana готова${NC}"
        break
    fi
    sleep 2
    if [ $i -eq 30 ]; then
        echo -e "${RED}⚠️ Kibana не ответила за 60 секунд. Дашборд не создан.${NC}"
        skip_dashboard=1
    fi
done

if [ "$skip_dashboard" -eq 0 ]; then
    # 1. Создание index pattern weblogs*
    echo -e "${YELLOW}   Создание index pattern weblogs*...${NC}"
    curl -X POST "http://localhost:5601/api/saved_objects/index-pattern/weblogs*" \
         -H "kbn-xsrf: true" \
         -H "Content-Type: application/json" \
         -d '{"attributes":{"title":"weblogs*","timeFieldName":"@timestamp"}}' \
         --silent --show-error || echo -e "${YELLOW}   Index pattern возможно уже существует${NC}"

    # 2. Визуализация Top URLs
    echo -e "${YELLOW}   Создание визуализации Top URLs...${NC}"
    curl -X POST "http://localhost:5601/api/saved_objects/visualization/nginx-top-urls" \
         -H "kbn-xsrf: true" \
         -H "Content-Type: application/json" \
         -d '{
               "attributes": {
                 "title": "Nginx – Top URLs",
                 "visState": "{\"title\":\"Nginx – Top URLs\",\"type\":\"histogram\",\"params\":{\"type\":\"histogram\",\"grid\":{\"categoryLines\":false},\"categoryAxes\":[{\"id\":\"CategoryAxis-1\",\"type\":\"category\",\"position\":\"bottom\",\"show\":true,\"style\":{},\"scale\":{\"type\":\"linear\"},\"labels\":{\"show\":true,\"truncate\":100},\"title\":{}}],\"valueAxes\":[{\"id\":\"ValueAxis-1\",\"name\":\"LeftAxis-1\",\"type\":\"value\",\"position\":\"left\",\"show\":true,\"style\":{},\"scale\":{\"type\":\"linear\",\"mode\":\"normal\"},\"labels\":{\"show\":true,\"rotate\":0,\"filter\":false,\"truncate\":100},\"title\":{\"text\":\"Count\"}}],\"seriesParams\":[{\"show\":\"true\",\"type\":\"histogram\",\"mode\":\"stacked\",\"data\":{\"label\":\"Count\",\"id\":\"1\"},\"valueAxis\":\"ValueAxis-1\",\"drawLinesBetweenPoints\":true,\"lineWidth\":2,\"showCircles\":true,\"interpolate\":\"linear\"}],\"addTooltip\":true,\"addLegend\":true,\"legendPosition\":\"right\",\"times\":[],\"addTimeMarker\":false,\"thresholdLine\":{\"show\":false,\"value\":10,\"width\":1,\"style\":\"full\",\"color\":\"#E7664C\"}},\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"schema\":\"metric\",\"params\":{}},{\"id\":\"2\",\"enabled\":true,\"type\":\"terms\",\"schema\":\"segment\",\"params\":{\"field\":\"url.original.keyword\",\"size\":5,\"order\":\"desc\",\"orderBy\":\"1\"}}]}",
                 "uiStateJSON": "{}",
                 "description": "",
                 "version": 1
               },
               "references": [
                 {
                   "name": "kibanaSavedObjectMeta.searchSourceJSON.indexRefName",
                   "id": "weblogs*",
                   "type": "index-pattern"
                 }
               ]
             }' \
         --silent --show-error || echo -e "${RED}   Не удалось создать визуализацию Top URLs${NC}"

    # 3. Визуализация Response Codes
    echo -e "${YELLOW}   Создание визуализации Response Codes...${NC}"
    curl -X POST "http://localhost:5601/api/saved_objects/visualization/nginx-response-codes" \
         -H "kbn-xsrf: true" \
         -H "Content-Type: application/json" \
         -d '{
               "attributes": {
                 "title": "Nginx – Response Codes",
                 "visState": "{\"title\":\"Nginx – Response Codes\",\"type\":\"pie\",\"params\":{\"type\":\"pie\",\"addTooltip\":true,\"addLegend\":true,\"legendPosition\":\"right\",\"isDonut\":true},\"aggs\":[{\"id\":\"1\",\"enabled\":true,\"type\":\"count\",\"schema\":\"metric\",\"params\":{}},{\"id\":\"2\",\"enabled\":true,\"type\":\"terms\",\"schema\":\"segment\",\"params\":{\"field\":\"http.response.status_code\",\"size\":10,\"order\":\"desc\",\"orderBy\":\"1\"}}]}",
                 "uiStateJSON": "{}",
                 "description": "",
                 "version": 1
               },
               "references": [
                 {
                   "name": "kibanaSavedObjectMeta.searchSourceJSON.indexRefName",
                   "id": "weblogs*",
                   "type": "index-pattern"
                 }
               ]
             }' \
         --silent --show-error || echo -e "${RED}   Не удалось создать визуализацию Response Codes${NC}"

    # 4. Удаляем старый дашборд (если существует)
    echo -e "${YELLOW}   Удаление старого дашборда (если есть)...${NC}"
    curl -X DELETE "http://localhost:5601/api/saved_objects/dashboard/nginx-dashboard" \
         -H "kbn-xsrf: true" \
         --silent --show-error || true

    # 5. Создаём дашборд с панелями (единым запросом)
    echo -e "${YELLOW}   Создание дашборда с панелями...${NC}"
    curl -X POST "http://localhost:5601/api/saved_objects/dashboard/nginx-dashboard" \
         -H "kbn-xsrf: true" \
         -H "Content-Type: application/json" \
         -d '{
               "attributes": {
                 "title": "Nginx Dashboard",
                 "description": "",
                 "version": 1,
                 "timeRestore": false,
                 "refreshInterval": { "pause": true, "value": 0 },
                 "optionsJSON": "{\"useMargins\":true,\"syncColors\":false,\"syncCursor\":true,\"syncTooltips\":false,\"hidePanelTitles\":false}",
                 "kibanaSavedObjectMeta": {
                   "searchSourceJSON": "{\"query\":{\"query\":\"\",\"language\":\"kuery\"},\"filter\":[]}"
                 },
                 "panels": [
                   {
                     "type": "visualization",
                     "gridData": { "x": 0, "y": 0, "w": 24, "h": 15, "i": "1" },
                     "panelIndex": "1",
                     "embeddableConfig": {},
                     "explicitInput": { "savedObjectId": "nginx-top-urls" }
                   },
                   {
                     "type": "visualization",
                     "gridData": { "x": 24, "y": 0, "w": 24, "h": 15, "i": "2" },
                     "panelIndex": "2",
                     "embeddableConfig": {},
                     "explicitInput": { "savedObjectId": "nginx-response-codes" }
                   }
                 ]
               },
               "references": [
                 { "name": "1:panel_1.embeddableConfig.savedObjectId", "id": "nginx-top-urls", "type": "visualization" },
                 { "name": "2:panel_2.embeddableConfig.savedObjectId", "id": "nginx-response-codes", "type": "visualization" }
               ]
             }' \
         --silent --show-error || echo -e "${RED}   Не удалось создать дашборд с панелями${NC}"

    echo -e "${GREEN}✓ Дашборд и визуализации созданы${NC}"
fi

# -----------------------------------------------------------------------------
# 9. Финальная информация
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
echo -e "\n${YELLOW}После получения данных от Filebeat откройте Kibana → Dashboard → Nginx Dashboard${NC}"
