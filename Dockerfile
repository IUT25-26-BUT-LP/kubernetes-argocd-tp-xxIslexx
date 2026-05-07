FROM nginx:1.27-alpine
RUN echo "<h1>Defi 4</h1>" > /usr/share/nginx/html/index.html
EXPOSE 80
