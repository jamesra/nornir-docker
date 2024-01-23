#!/bin/bash

volume='rc5'
container_name="nornir-${volume}"
output=$(docker ps --filter name=${container_name})
if [[ ! $output =~ $container_name ]]; then
    echo "$container_name container does not exist"
    docker run --name $container_name -it -d --tmpfs /tmp --gpus all --cap-add SYS_ADMIN --cap-add DAC_READ_SEARCH -v /home/paul/src/marclab/nornir-testdata/:/test-data nornir_cupy:latest
fi

docker exec $container_name /bin/bash -c 'echo export TESTINPUTPATH=/test-data >> ~/.bashrc'
docker exec $container_name /bin/bash -c 'echo export TESTOUTPUTPATH=/test-data-out >> ~/.bashrc'
docker exec $container_name /bin/bash -c 'mkdir /test-data-out'
docker exec -it $container_name bash
