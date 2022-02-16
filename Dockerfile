#
# Installs WordPress with wp-cli (wp.cli.org) installed; then, adds plugins and a sample theme
#

FROM wordpress:latest

# Add sudo in order to run wp-cli as the www-data user 
RUN apt-get update && apt-get install -y sudo less wget

# Add WP-CLI 
RUN curl -o /bin/wp-cli.phar https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar
COPY wp-su.sh /bin/wp
RUN chmod +x /bin/wp-cli.phar /bin/wp

# Install a sample theme and activate it (just to show how to add more themes to the base image)
RUN wp theme install hello-elementor --activate

# Install:
# - a Microsoft plugin to store uploaded media on Azure Storage Account instead of local disk
# - W3 Total Cache plugin to enable Azure CDN
RUN wp plugin install windows-azure-storage --activate && \
    wp plugin install w3-total-cache --activate

# Cleanup
RUN apt-get clean && rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*
