FROM ubuntu:20.04

USER root
ARG DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt install -y wget git build-essential libgdal-dev libnetcdf-c++4-dev libnetcdf-cxx-legacy-dev libnetcdf-dev netcdf-bin libboost-all-dev cmake cmake-curses-gui
RUN wget https://github.com/Kitware/CMake/releases/download/v3.30.2/cmake-3.30.2-linux-x86_64.tar.gz
RUN tar -xvf cmake-3.30.2-linux-x86_64.tar.gz
RUN mv cmake-3.30.2-linux-x86_64 /opt/cmake-3.30.2
RUN ln -s /opt/cmake-3.30.2/bin/cmake /usr/local/bin/cmake
RUN git clone https://github.com/UtahEFD/QES-Public.git
RUN cd QES-Public && \
    mkdir build && \
    cd build && \
    cmake ..  && \
    make

    CMD /usr/bin/bash -c /QES-Public/build/qesWinds/qesWinds
    VOLUME /data
    WORKDIR /data

