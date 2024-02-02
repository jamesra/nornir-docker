$volume = 'test'
$container_name = "nornir-$volume"
$test_input_path = "C:/src/git/nornir-testdata"
$test_output_path = "C:/Temp"
$output = [string](docker ps --filter name=$($container_name))
Write-Host $output
if (-not ($output.Contains($container_name))) {
    Write-Host "$container_name container does not exist"
    docker run --name $container_name -it -d --tmpfs /tmp --cap-add SYS_ADMIN --cap-add DAC_READ_SEARCH -v //storage2.connectomes.utah.edu/Data:/mnt/storage2 -v ${test_input_path}:/mnt/testinput -v ${test_output_path}:/mnt/testoutput -e TESTINPUTPATH=/mnt/testinput -e TESTOUTPUTPATH=/mnt/testoutput nornir
} 

wt docker exec -it $container_name bash
