FROM nginx:1.27-alpine
# Replace the default site with our reverse-proxy config
RUN rm /etc/nginx/conf.d/default.conf
COPY nginx.conf /etc/nginx/conf.d/app.conf
# Ship the static frontend
COPY html/ /usr/share/nginx/html/
EXPOSE 80
