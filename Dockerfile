FROM php:7.4-apache

COPY public/ /var/www/html/

RUN apt-get update && apt-get upgrade -y \
    && apt-get install -y ssl-cert \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

RUN docker-php-ext-install mysqli && docker-php-ext-enable mysqli \
    && a2enmod headers \
    && sed -ri -e 's/^([ \t]*)(<\/VirtualHost>)/\1\tHeader set Access-Control-Allow-Origin "*"\n\1\2/g' /etc/apache2/sites-available/*.conf
RUN mkdir /var/www/html/wp-content/cache/ /var/www/html/wp-content/uploads/ \
    && chown -R www-data:www-data /var/www/html/wp-content/ /var/www/html/wp-config.php \
    && chmod -R 755 /var/www/html/
