#!/bin/bash
set -e

echo "Running BeyondFA - bundle-wise FA, MD, AD, RD + merged output..."

# Paths
dwi_mha=$(find /input/images/dwi-4d-brain-mri -name "*.mha" | head -n 1)
json_file="/input/dwi-4d-acquisition-metadata.json"
basename=$(basename "$dwi_mha" .mha)
nifti_file="/tmp/${basename}.nii.gz"
bval_file="/tmp/${basename}.bval"
bvec_file="/tmp/${basename}.bvec"
output_dir="/output"
work_dir="/tmp/tractseg_work"
mkdir -p "$work_dir"

echo "Converting input files..."
python convert_mha_to_nifti.py "$dwi_mha" "$nifti_file"
python convert_json_to_bvalbvec.py "$json_file" "$bval_file" "$bvec_file"

echo "Preprocessing (mask + response)..."
mask="$work_dir/mask.nii.gz"
response="$work_dir/response.txt"
dwi2mask "$nifti_file" "$mask" -fslgrad "$bvec_file" "$bval_file" -force
dwi2response fa "$nifti_file" "$response" -fslgrad "$bvec_file" "$bval_file" -force

echo "Computing FODs and peaks..."
fod="$work_dir/WM_FODs.nii.gz"
peaks="$work_dir/peaks.nii.gz"
dwi2fod csd "$nifti_file" "$response" "$fod" -mask "$mask" -fslgrad "$bvec_file" "$bval_file" -force
sh2peaks "$fod" "$peaks" -mask "$mask" -force

echo "Segmenting bundles using TractSeg..."
TractSeg -i "$peaks" -o "$work_dir" --bvals "$bval_file" --bvecs "$bvec_file" --brain_mask "$mask" --keep_intermediate_files

echo "Computing DTI metrics: FA, MD, AD, RD..."
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

bundle_dir="$work_dir/bundle_segmentations"
bundle_list=$(find "$bundle_dir" -name "*.nii.gz" | sort)

# Init average list only
avg_list=()

echo "Computing mean values per bundle..."
for roi in $bundle_list; do
    name=$(basename "$roi" .nii.gz)
    voxels=$(fslstats "$roi" -V | awk '{print $1}')
    if [ "$voxels" -eq 0 ]; then
        fa=0; md=0; ad=0; rd=0
    else
        fa=$(fslstats "$metric_dir/fa.nii.gz" -k "$roi" -m)
        md=$(fslstats "$metric_dir/md.nii.gz" -k "$roi" -m)
        ad=$(fslstats "$metric_dir/ad.nii.gz" -k "$roi" -m)
        rd=$(fslstats "$metric_dir/rd.nii.gz" -k "$roi" -m)
    fi

    # Format
    fa=$(printf "%.6f" "$fa" | sed 's/^\./0./')
    md=$(printf "%.6f" "$md" | sed 's/^\./0./')
    ad=$(printf "%.6f" "$ad" | sed 's/^\./0./')
    rd=$(printf "%.6f" "$rd" | sed 's/^\./0./')
    mean_bundle=$(echo "scale=8; ($fa + $md + $ad + $rd) / 4" | bc -l)
    mean_bundle=$(printf "%.6f" "$mean_bundle" | sed 's/^\./0./')

    echo "$name: AVG=$mean_bundle"
    avg_list+=("$mean_bundle")
done

# Pad to 128
while [ "${#avg_list[@]}" -lt 128 ]; do
    avg_list+=(0)
done

# Write only final features file
write_json() {
    arr=("$@")
    file="${arr[-1]}"
    unset 'arr[${#arr[@]}-1]'
    {
        echo "["
        for i in "${!arr[@]}"; do
            if [ "$i" -lt $((${#arr[@]} - 1)) ]; then
                echo "  ${arr[$i]},"
            else
                echo "  ${arr[$i]}"
            fi
        done
        echo "]"
    } > "$file"
}

echo "Saving features file to $output_dir/features-128.json"
write_json "${avg_list[@]}" "$output_dir/features-128.json"

echo "Done. Output file:"
echo "  - $output_dir/features-128.json"
