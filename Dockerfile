# Définition des arguments pour les versions des différents composants
ARG PHP_VERSION=8.1
ARG NODE_VERSION=16
ARG NGINX_VERSION=1.21
ARG ALPINE_VERSION=3.15
ARG COMPOSER_VERSION=2.4
ARG PHP_EXTENSION_INSTALLER_VERSION=latest

# Étape de construction pour Composer
FROM composer:${COMPOSER_VERSION} AS composer

# Étape de construction pour l'installateur d'extensions PHP
FROM mlocati/php-extension-installer:${PHP_EXTENSION_INSTALLER_VERSION} AS php_extension_installer

# Étape de base pour PHP
FROM php:${PHP_VERSION}-fpm-alpine${ALPINE_VERSION} AS base

# Installation des dépendances persistantes / de runtime
RUN apk add --no-cache \
        acl \
        file \
        gettext \
        unzip \
    ;

# Copie de l'installateur d'extensions PHP
COPY --from=php_extension_installer /usr/bin/install-php-extensions /usr/local/bin/

# Installation des extensions PHP par défaut
RUN install-php-extensions apcu exif gd intl pdo_mysql opcache zip

# Copie de Composer
COPY --from=composer /usr/bin/composer /usr/bin/composer

# Configuration des fichiers php.ini et opcache.ini
COPY docker/php/prod/php.ini        $PHP_INI_DIR/php.ini
COPY docker/php/prod/opcache.ini    $PHP_INI_DIR/conf.d/opcache.ini

# Copie du fichier requis par opcache preloading
COPY config/preload.php /srv/sylius/config/preload.php

# Définition de l'environnement pour Composer
ENV COMPOSER_ALLOW_SUPERUSER=1

# Nettoyage du cache de Composer
RUN set -eux; \
    composer clear-cache

# Ajout du chemin pour l'exécution de scripts Composer
ENV PATH="${PATH}:/root/.composer/vendor/bin"

# Définition du répertoire de travail
WORKDIR /srv/sylius

# Définition de l'environnement pour la production
ENV APP_ENV=prod

# Installation des dépendances PHP sans les scripts et les devDependencies
COPY composer.* symfony.lock ./
RUN set -eux; \
    COMPOSER_MEMORY_LIMIT=-1 composer install --prefer-dist --no-autoloader --no-interaction --no-scripts --no-progress --no-dev ; \
    composer clear-cache

# Copie des fichiers spécifiques nécessaires à l'application
COPY .env .env.prod ./
COPY assets assets/
COPY bin bin/
COPY config config/
COPY public public/
COPY src src/
COPY templates templates/
COPY translations translations/

# Génération de l'autoload
RUN set -eux; \
    mkdir -p var/cache var/log; \
    composer dump-autoload --classmap-authoritative; \
    APP_SECRET='' composer run-script post-install-cmd; \
    chmod +x bin/console; sync; \
    bin/console sylius:install:assets --no-interaction; \
    bin/console sylius:theme:assets:install public --no-interaction

# Définition des volumes
VOLUME /srv/sylius/var
VOLUME /srv/sylius/public/media

# Copie du script d'entrée Docker pour PHP
COPY docker/php/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# Définition de l'entrée et de la commande par défaut pour l'exécution de PHP-FPM
ENTRYPOINT ["docker-entrypoint"]
CMD ["php-fpm"]

# Étape de construction pour Node.js
FROM node:${NODE_VERSION}-alpine${ALPINE_VERSION} AS sylius_node

# Définition du répertoire de travail pour Node.js
WORKDIR /srv/sylius

# Installation des dépendances Node.js
RUN set -eux; \
	apk add --no-cache --virtual .build-deps \
		g++ \
		gcc \
		make \
	;

# Installation des dépendances Node.js pour l'application
COPY package.json yarn.* ./
RUN set -eux; \
    yarn install; \
    yarn cache clean

# Copie des fichiers nécessaires à l'application depuis l'étape PHP de base
COPY --from=base /srv/sylius/vendor/sylius/sylius/src/Sylius/Bundle/UiBundle/Resources/private       vendor/sylius/sylius/src/Sylius/Bundle/UiBundle/Resources/private/
COPY --from=base /srv/sylius/vendor/sylius/sylius/src/Sylius/Bundle/AdminBundle/Resources/private    vendor/sylius/sylius/src/Sylius/Bundle/AdminBundle/Resources/private/
COPY --from=base /srv/sylius/vendor/sylius/sylius/src/Sylius/Bundle/ShopBundle/Resources/private     vendor/sylius/sylius/src/Sylius/Bundle/ShopBundle/Resources/private/
COPY --from=base /srv/sylius/assets ./assets

# Construction des assets pour l'application
COPY webpack.config.js ./
RUN yarn build:prod

# Copie du script d'entrée Docker pour Node.js
COPY docker/node/docker-entrypoint.sh /usr/local/bin/docker-entrypoint
RUN chmod +x /usr/local/bin/docker-entrypoint

# Définition de l'entrée et de la commande par défaut pour l'exécution de Node.js
ENTRYPOINT ["docker-entrypoint"]
CMD ["yarn", "build:prod"]

# Étape finale pour PHP en mode production
FROM base AS sylius_php_prod

# Copie des assets générés par Node.js
COPY --from=sylius_node /srv/sylius/public/build public/build

# Étape finale pour NGINX
FROM nginx:${NGINX_VERSION}-alpine AS sylius_nginx

# Configuration de NGINX
COPY docker/nginx/conf.d/default.conf /etc/nginx/conf.d/

# Copie des fichiers Symfony et des assets publics depuis l'étape PHP de base
COPY --from=base        /srv/sylius/public public/
COPY --from=sylius_node /srv/sylius/public public/

# Étape finale pour PHP en mode développement
FROM base AS sylius_php_dev

# Configuration des fichiers php.ini et opcache.ini pour le mode développement
COPY docker/php/dev/php.ini        $PHP_INI_DIR/php.ini
COPY docker/php/dev/opcache.ini    $PHP_INI_DIR/conf.d/opcache.ini

# Définition de l'environnement pour le développement
ENV APP_ENV=dev

# Copie des fichiers pour le mode développement et installation des dépendances PHP
COPY .env.test .env.test_cached ./
RUN set -eux; \
    composer install --prefer-dist --no-autoloader --no-interaction --no-scripts --no-progress; \
    composer clear-cache

# Étape pour les tâches planifiées
FROM sylius_php_prod AS sylius_cron

# Installation des dépendances pour les tâches planifiées
RUN set -eux; \
