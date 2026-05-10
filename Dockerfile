FROM 10.6.0.190:80/proxy/nginx:alpine
RUN apt update 
RUN echo "<h1>Defi 4</h1>" > /usr/share/nginx/html/index.html
EXPOSE 80

