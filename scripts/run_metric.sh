#!/bin/bash
set -e

echo "Running BeyondFA - bundle-wise FA, MD, AD, RD + merged output..."

# Find all dwi.mha files in /input
dwi_mha_files=$(find /input/images/dwi-4d-brain-mri -name "*.mha")

for dwi_mha_file in $dwi_mha_files; do
    # Set up file names
    json_file="/input/dwi-4d-acquisition-metadata.json"

    basename=$(basename "$dwi_mha_file" .mha)
    bval_file="/tmp/${basename}.bval"
    bvec_file="/tmp/${basename}.bvec"
    nifti_file="/tmp/${basename}.nii.gz"
    bval_path=$bval_file
    bvec_path=$bvec_file

    # Convert dwi.mha to nii.gz
    echo "Converting $dwi_mha_file to $nifti_file..."
    python convert_mha_to_nifti.py $dwi_mha_file $nifti_file

    # Convert json to bval and bvec
    echo "Converting $json_file to $bval_path and $bvec_path..."
    python convert_json_to_bvalbvec.py $json_file $bval_path $bvec_path

    # Define output directory
    output_dir="/output"
    work_dir="/tmp/tractseg_work"
    mkdir -p "$work_dir"

    # Create mask, response, FODs, and peaks
    echo "Preprocessing (mask + response)"
    mask="$work_dir/mask.nii.gz"
    response="$work_dir/response.txt"
    dwi2mask "$nifti_file" "$mask" -fslgrad "$bvec_file" "$bval_file" -force
    dwi2response fa "$nifti_file" "$response" -fslgrad "$bvec_file" "$bval_file" -force

    echo "Computing FODs and peaks"
    fod="$work_dir/WM_FODs.nii.gz"
    peaks="$work_dir/peaks.nii.gz"
    dwi2fod csd "$nifti_file" "$response" "$fod" -mask "$mask" -fslgrad "$bvec_file" "$bval_file" -force
    sh2peaks "$fod" "$peaks" -mask "$mask" -force

    # Run TractSeg
    echo "Segmenting bundles using TractSeg"
    TractSeg -i "$peaks" -o "$work_dir" --bvals "$bval_file" --bvecs "$bvec_file" --brain_mask "$mask" --keep_intermediate_files

    # Run FA, MD, AD and RD calculation
    echo "Computing DTI metrics: FA, MD, AD, RD"
    metric_dir="$work_dir/metrics"
    
    mkdir -p "$metric_dir"
    scil_dti_metrics.py --mask "$mask" \
        --fa "$metric_dir/fa.nii.gz" \
        --md "$metric_dir/md.nii.gz" \
        --ad "$metric_dir/ad.nii.gz" \
        --rd "$metric_dir/rd.nii.gz" \
        "$nifti_file" "$bval_file" "$bvec_file" -f

    echo "DTI metrics generated:"
    ls -lh "$metric_dir"

    # Compute average of calculation per bundle

    roi_list=$(find "$work_dir/bundle_segmentations" -name "*.nii.gz" | sort)

    echo "Computing mean values per bundle"

    for metric in fa md ad rd; do
        scil_volume_stats_in_ROI.py \
            --metrics "$metric_dir/${metric}.nii.gz" \
            --bin \
            $roi_list
    done

    echo "Done. Output file:"
    echo "  - $output_dir/features-128.json"
done
