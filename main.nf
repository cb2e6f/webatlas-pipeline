#!/usr/bin/env/ nextflow

// Copyright (C) 2022 Tong LI <tongli.bioinfo@protonmail.com>
import groovy.json.*

nextflow.enable.dsl=2

// Default params
params.title = ""
params.images = []
params.factors = []
params.codebook = ""
params.max_n_worker = 30
params.dataset = ""
params.zarr_dirs = []
params.data = []
params.url = ""

params.options = []
params.layout = "minimal"
params.custom_layout = ""
params.outdir = ""
params.config_files = []

// if directly writing to s3
params.s3 = false
params.s3_keys = ["YOUR_ACCESS_KEY", "YOUR_SECRETE_KEY"]
params.outdir_s3 = "cog.sanger.ac.uk/webatlas/"


verbose_log = true
version = "0.0.1"

process image_to_zarr {
    tag "${image}"
    debug false

    container "openmicroscopy/bioformats2raw:0.4.0"
    storeDir params.outdir

    input:
    tuple val(img_type), file(image)
    tuple val(accessKey), val(secretKey)
    val output_s3

    output:
    /*val out_s3, emit: s3_path*/
    path img_type

    script:
    out_s3 = "${output_s3}/${img_type}"
    """
    #/opt/bioformats2raw/bin/bioformats2raw --output-options "s3fs_access_key=${accessKey}|s3fs_secret_key=${secretKey}|s3fs_path_style_access=true" \
        #${image} s3://${out_s3}
    /opt/bioformats2raw/bin/bioformats2raw ${image} ${img_type}
    """
}

process condolidate_metadata{
    tag "${zarr}"
    /*debug verbose_log*/
    container "hamat/webatlas-zarr:${version}"

    input:
    path zarr

    script:
    """
    consolidate_md.py ${zarr}
    """
}

process route_file {
    debug verbose_log
    tag "${type}"

    container "hamat/webatlas-router"
    publishDir params.outdir, mode: "copy"

    input:
    tuple val(type), file(file), val(args)

    output:
    stdout emit: out_file_paths
    path("*"), emit: out_files, optional: true

    script:
    args_strs = []
    if (args) {
        args.each { arg, value ->
            if (value instanceof Collection){
                value = value.collect { it instanceof String ? /\'/ + it.replace(" ",/\ /) + /\'/ : it }
                concat_args = value.join(',')
            }
            else
                concat_args = value
            args_strs.add("--$arg $concat_args")
        }
    }
    args_str = args_strs.join(' ')

    """
    router.py --type ${type} --file ${file} ${args_str}
    """
}

process Build_config{
    tag "config"
    debug verbose_log
    container "hamat/webatlas-build-config:${version}"
    publishDir params.outdir, mode: "copy"

    input:
        val(dir)
        val(title)
        val(dataset)
        val(url)
        val(zarr_dirs)
        val(files)
        val(options)
        val(layout)
        val(custom_layout)
        file(codebook)

    output:
        file("config.json")

    script:
    files = files.collect{ /\'/ + it.trim() + /\'/ }
    zarr_dirs = zarr_dirs.collect{ /\'/ + it.trim() + /\'/ }

    file_paths = files ? "--file_paths [" + files.join(',') + "]": ""
    zarr_dirs_str = zarr_dirs ? "--zarr_dirs [" + zarr_dirs.join(',') + "]" : ""
    url_str = url?.trim() ? "--url ${url}" : ""
    clayout_str = custom_layout?.trim() ? "--custom_layout \"${custom_layout}\"" : ""
    """
    build_config.py \
        --title "${title}" \
        --dataset ${dataset} \
        --files_dir ${dir} ${zarr_dirs_str} \
        --options ${options} \
        ${file_paths} ${url_str} \
        --layout ${layout} ${clayout_str} \
        --codebook ${codebook}
    """
}

process Build_config_local{
    tag "config"
    debug verbose_log
    container "hamat/webatlas-build-config:${version}"
    publishDir params.outdir, mode: "copy"

    input:
        path(dir)
        val(title)
        val(dataset)
        val(url)
        path(zarr_dirs)
        path(files)
        val(options)
        val(layout)
        val(custom_layout)
        file(codebook)

    output:
        file("config.json")

    script:
    files = files.collect{ /\'/ + it + /\'/ }
    zarr_dirs = zarr_dirs.collect{ /\'/ + it + /\'/ }

    file_paths = files ? "--file_paths [" + files.join(',') + "]": ""
    zarr_dirs_str = zarr_dirs ? "--zarr_dirs [" + zarr_dirs.join(',') + "]" : ""
    url_str = url?.trim() ? "--url ${url}" : ""
    clayout_str = custom_layout?.trim() ? "--custom_layout \"${custom_layout}\"" : ""
    """
    build_config.py \
        --title "${title}" \
        --dataset ${dataset} \
        --files_dir ${dir} ${zarr_dirs_str} \
        --options ${options} \
        ${file_paths} ${url_str} \
        --layout ${layout} ${clayout_str} \
        --codebook ${codebook}
    """
}

process generate_label_image {
    tag "${h5ad}"
    debug verbose_log
    container "generate_label:latest"
    publishDir params.outdir, mode: "copy"

    input:
        path h5ad

    output:
        file("${stem}_with_label.zarr")

    script:
    stem = h5ad.baseName
    """
    generate_label.py --stem "${stem}" --h5ad ${h5ad}
    """

}

workflow {
    generate_label_image(channel.fromPath(params.h5ad))
    /*Process_files()*/
    // Process_files.out.files.toList().view()
}

workflow To_ZARR {
    if (params.images) {
        channel.from(params.images)
            .map{it -> [it[0], file(it[1])]}
            .set{image_to_convert}
        image_to_zarr(image_to_convert, params.s3_keys, params.outdir_s3)
        condolidate_metadata(image_to_zarr.out)
        zarr_dirs = image_to_zarr.out.collect()
    }
    else
        zarr_dirs = []

    emit:
        zarr_dirs = zarr_dirs
}

workflow Process_files {
    if (params.data){
        data_list = []
        params.data.each { data_type, data_map ->
            data_list.add([data_type, file(data_map.file), data_map.args])
        }
        route_file(Channel.from(data_list))
        files = route_file.out.out_files.collect{ it.flatten() }
        file_paths = route_file.out.out_file_paths.collect{ it.split('\n').flatten() }
    }
    else {
        files = []
        file_paths = []
    }

    emit:
        files = files
        file_paths = file_paths
}

workflow Full_pipeline {
    To_ZARR()

    Process_files()

    options_str = /"/ + new JsonBuilder(params.options).toString().replace(/"/,/\"/).replace(/'/,/\'/) + /"/

    // Build config from files generated from Process_files
    // Ignores files in params.outdir
    if (!params.s3){
        Build_config_local(
            file("''"),
            params.title,
            params.dataset,
            params.url,
            To_ZARR.out.zarr_dirs,
            Process_files.out.files,
            options_str,
            params.layout,
            params.custom_layout,
            channel.fromPath(params.codebook)
        )
    }
    else {
        Build_config(
            "''",
            params.title,
            params.dataset,
            params.url,
            To_ZARR.out.zarr_dirs,
            Process_files.out.file_paths,
            options_str,
            params.layout,
            params.custom_layout,
            channel.fromPath(params.codebook)
        )
    }
}

workflow Config_from_paths {
    if (params.config_files){

        options_str = /"/ + new JsonBuilder(params.options).toString().replace(/"/,/\"/).replace(/'/,/\'/) + /"/

        Build_config(
            params.outdir,
            params.title,
            params.dataset,
            params.url,
            params.zarr_dirs,
            params.config_files,
            options_str,
            params.layout,
            params.custom_layout
        )
    }
}

workflow Config_from_dir {
    options_str = /"/ + new JsonBuilder(params.options).toString().replace(/"/,/\"/).replace(/'/,/\'/) + /"/

    if (!params.s3){
        // Build config from files in params.outdir
        Build_config_local(
            params.outdir,
            params.title,
            params.dataset,
            params.url,
            [],
            [],
            options_str,
            params.layout,
            params.custom_layout,
            channel.fromPath(params.codebook)
        )
    }
}
