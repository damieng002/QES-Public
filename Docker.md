# Build and Run Docker Image

## Build QES-Winds Image
`docker build -t qes-winds .`

## Run QES-Winds Image
- Go to the directory with your configuration (xml) file and all that QES-Winds need
- `docker run --rm -i -v `pwd`:/data qes-winds /QES-Public/build/qesWinds/qesWinds -q <conf_file.xml> -o <output_name>`