#FROM python:3.10.12-bullseye
FROM ubuntu:latest

ARG DEBIAN_FRONTEND=noninteractive
ARG MAGICKVERSION=7.1.1-27

RUN apt-get update
RUN apt-get upgrade -y
RUN apt-get install python3.10 python3-pip  -y
RUN pip install --upgrade pip
RUN apt-get install git -y

#Python 
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1
RUN update-alternatives --config python


#Image magick dependencies
RUN apt-get install -y wget
RUN apt-get install -y autoconf pkg-config


###################################################################################################################
#Update the git key per this blog post: https://github.blog/2023-03-23-we-updated-our-rsa-ssh-host-key/
#RUN su
RUN mkdir -p ~/.ssh
RUN touch ~/.ssh/known_hosts
RUN echo SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s >> ~/.ssh/known_hosts
#RUN ssh-keyscan -t rsa github.com >> ~/.ssh/known_hosts
#RUN ssh-keygen -R github.com
#RUN curl -L https://api.github.com/meta | jq -r '.ssh_keys | .[]' | sed -e 's/^/github.com /' >> ~/.ssh/known_hosts
###################################################################################################################

###################################################################################################################
#Install Image Magick and add it to /bin so it is available from the command line
# Releases available here: https://github.com/ImageMagick/ImageMagick/releases/
# Instructions found here: https://stackoverflow.com/questions/74951619/how-to-install-imagemagick-7-on-ubuntu-image
WORKDIR /usr/src
RUN mkdir ImageMagick
WORKDIR /usr/src/ImageMagick

RUN apt-get install -y build-essential curl libpng-dev

#Download Image Magick of desired version
RUN wget https://github.com/ImageMagick/ImageMagick/archive/refs/tags/$MAGICKVERSION.tar.gz && \
    tar xzf $MAGICKVERSION.tar.gz && \
    rm $MAGICKVERSION.tar.gz && \
    apt-get clean && \
    apt-get autoremove

#Build and install Image Magick
RUN sh ./ImageMagick-$MAGICKVERSION/configure --prefix=/usr/local --with-bzlib=yes --with-fontconfig=no --with-freetype=no --with-gslib=no --with-gvc=no --with-jpeg=yes --with-jp2=yes --with-png=yes --with-tiff=yes --with-xml=yes --with-gs-font-dir=no --enable-static=no 
RUN make -j
RUN make install
RUN ldconfig /usr/local/lib/

WORKDIR /usr/src
RUN rm -rf ImageMagick

#################################################################################################
# Create a folder for nornir source
WORKDIR /usr/src/app
RUN mkdir nornir
WORKDIR /usr/src/app/nornir

#################################################################################################
# This is a development environment. Map these folders to the source code on the host machine.
# For production environments that pull this image, install these packages from git or pip.
RUN git clone -b dev https://github.com/jamesra/nornir-shared
RUN git clone -b dev https://github.com/jamesra/nornir-pools
RUN git clone https://github.com/jamesra/dm4reader
RUN git clone -b dev https://github.com/jamesra/nornir-imageregistration
RUN git clone -b dev https://github.com/jamesra/nornir-buildmanager

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
#COPY nornir-projects.txt ./
#RUN pip install --no-cache-dir -r nornir-projects.txt

#################################################################################################
#Cleanup install, removes build environment
RUN apt-get remove -y build-essential  
RUN apt-get clean -y

COPY . .