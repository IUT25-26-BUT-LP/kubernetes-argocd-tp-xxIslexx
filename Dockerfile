FROM 10.6.0.190:80/proxy/nginx:alpine
# Introduit volontairement une version d'OpenSSL avec CVE connues pour démontrer la détection par Trivy
# RUN apk add --no-cache openssl=3.3.3-r0 || true 
RUN echo "<h1>Defi 4</h1>" > /usr/share/nginx/html/index.html
EXPOSE 80

