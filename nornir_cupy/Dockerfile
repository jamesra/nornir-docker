#FROM python:3.10.12-bullseye
#FROM ubuntu:latest
FROM cupy/cupy:latest

RUN apt-get update
RUN apt-get upgrade -y
RUN pip install --upgrade pip
RUN apt-get install imagemagick -y
RUN apt-get install git -y
 
RUN update-alternatives --install /usr/bin/python python /usr/bin/python3.10 1
RUN update-alternatives --config python

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

WORKDIR /usr/src/app
RUN mkdir nornir
WORKDIR /usr/src/app/nornir

RUN git clone -b dev https://github.com/jamesra/nornir-shared
RUN git clone -b dev https://github.com/jamesra/nornir-pools
RUN git clone https://github.com/jamesra/dm4reader
RUN git clone -b CuPy https://github.com/jamesra/nornir-imageregistration
RUN git clone -b dev https://github.com/jamesra/nornir-buildmanager

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY nornir-projects.txt ./
RUN pip install --no-cache-dir -r nornir-projects.txt

COPY . .