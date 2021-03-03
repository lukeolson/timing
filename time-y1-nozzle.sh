#! /bin/bash

set -e
set -x

TIMING_HOME=$(pwd)
TIMING_HOST=$(hostname)
TIMING_DATE=$(date +"%m-%d-%y")
TIMING_PLATFORM=$(uname)
TIMING_ARCH=$(uname -m)
TIMING_REPO="MTCam/timing.git"
TIMING_BRANCH="lassen-auto-timing"

# -- Install conda env, dependencies and MIRGE-Com via *emirge*
# --- remove old run if it exists
if [ -d "emirge" ]
then
    echo "Removing old timing run."
    mv -f emirge emirge.old
    rm -rf emirge.old &
fi
# --- grab emirge and install MIRGE-Com 
git clone https://github.com/illinois-ceesd/emirge.git
cd emirge
./install.sh --env-name=nozzle.timing.env

# -- Activate the env we just created above
export EMIRGE_HOME="${TIMING_HOME}/emirge"
source ${EMIRGE_HOME}/config/activate_env.sh

cd mirgecom

# -- Grab and merge the branch with nozzle-dependent features
git fetch https://github.com/illinois-ceesd/mirgecom.git y1_production:y1_production
Y1_HASH=$(git rev-parse y1_production)
git checkout master
MIRGE_HASH=$(git rev-parse master)
git branch -D temp || true
git switch -c temp
git merge y1_production --no-edit

# -- Grab the repo with the nozzle driver
rm -Rf CEESD-Y1_nozzle
git clone https://github.com/anderson2981/CEESD-Y1_nozzle.git


# -- Edit the driver for:
# --- 20 steps
# --- no i/o
# --- desired file namings
cd CEESD-Y1_nozzle/startup
DRIVER_HASH=$(git rev-parse main)
sed -e 's/\(nviz = \).*/\11000/g' \
    -e 's/\(nrestart = \).*/\11000/g' \
    -e 's/\(current_dt = \).*/\15e-8/g' \
    -e 's/\(t_final = \).*/\11e-6/g' \
    -e 's/y0_euler/nozzle-timing/g' \
    -e 's/y0euler/nozzle-timing/g' \
    -e 's/mode="wu"/mode="wo"/' \
    -e 's/\(casename = \).*/\1"nozzle-timing"/g' < ./nozzle.py > ./nozzle_timing.py

# -- Get an MD5Sum for the untracked nozzle_timing driver
DRIVER_MD5SUM="None"
if command -v md5sum &> /dev/null
then 
    DRIVER_MD5SUM=$(md5sum ./nozzle_timing.py | cut -d " " -f 1)
else
    echo "Warning: No md5sum command found. Skipping  md5sum for untracked driver."
fi

# -- Run the case (platform-dependent)
echo RUNNING
case $TIMING_HOST in

    # --- Run the timing test in a batch job on Lassen@LLC
    lassen*)
        printf "Host: Lassen\n"
        rm -f nozzle_timing_job.sh
        rm -f timing-run-done
        # ---- Generate a batch script for running the timing job
        cat <<EOF > nozzle_timing_job.sh
#!/bin/bash
#BSUB -nnodes 1
#BSUB -G uiuc
#BSUB -W 30
#BSUB -q pdebug

printf "Running with EMIRGE_HOME=${EMIRGE_HOME}\n"

source "${EMIRGE_HOME}/config/activate_env.sh"
export PYOPENCL_CTX="port:tesla"
export XDG_CACHE_HOME="/tmp/$USER/xdg-scratch"

rm -f timing-run-done
jsrun -g 1 -a 1 -n 1 python -O -u -m mpi4py ./nozzle_timing.py
touch timing-run-done

EOF
        chmod +x nozzle_timing_job.sh
        # ---- Submit the batch script and wait for the job to finish
        bsub nozzle_timing_job.sh
        # ---- Wait 2 minutes right off the bat (the job is at least 90 sec)
        sleep 120
        iwait=0
        while [ ! -f ./timing-run-done ]; do 
            iwait=$((iwait+1))
            if [ "$iwait" -gt 360 ]; then # give up after 1 hour
                printf "Timed out waiting on batch job.\n"
                exit 1 # skip the rest of the script
            fi
            sleep 10
        done
        ;;

    # --- Run the timing test on an unknown/generic machine 
    *)
        printf "Host: Unknown\n"
        PYOPENCL_TEST=port:pthread python -m mpi4py ./nozzle_timing.py
        ;;
esac

# -- Process the results of the timing run
if [[ -f "nozzle-timing.sqlite-rank0" ]]; then

    rm -f nozzle_timings.yaml

    # --- Pull the timings out of the SQLITE files generated by logging
    STARTUP_TIME=`sqlite3 nozzle-timing.sqlite-rank0 'select SUM(value) from t_step WHERE step BETWEEN 0 and 0;'`
    FIRST_10_STEPS=`sqlite3 nozzle-timing.sqlite-rank0 'select SUM(value) from t_step WHERE step BETWEEN 0 and 10;'`
    SECOND_10_STEPS=`sqlite3 nozzle-timing.sqlite-rank0 'select SUM(value) from t_step WHERE step BETWEEN 11 and 20;'`

    # --- Create a YAML-compatible text snippet with the timing info
    printf "run_date: ${TIMING_DATE}\nrun_host: ${TIMING_HOST}\n" > nozzle_timings.yaml
    printf "run_platform: ${TIMING_PLATFORM}\nrun_arch: ${TIMING_ARCH}\n" >> nozzle_timings.yaml
    printf "mirge_version: ${MIRGE_HASH}\ny1_version: ${Y1_HASH}\n" >> nozzle_timings.yaml
    printf "driver_version: ${DRIVER_HASH}\ndriver_md5sum: ${DRIVER_MD5SUM}\n" >> nozzle_timings.yaml
    printf "time_startup: ${STARTUP_TIME}\ntime_first_10: ${FIRST_10_STEPS}\n" >> nozzle_timings.yaml
    printf "time_second_10: ${SECOND_10_STEPS}\n---\n" >> nozzle_timings.yaml
    
    # This snippet is failing on Lassen
    # requires SSH private key in file timing-key
    # requires corresponding public key in
    # https://github.com/illinois-ceesd/timing/settings/keys/new
    # 
    #    eval $(ssh-agent)
    #    trap "kill $SSH_AGENT_PID" EXIT
    #    ssh-add timing-key.pub

    # --- Update the timing data in the repo
    # ---- First, clone the timing repo
    git clone -b ${TIMING_BRANCH} git@github.com:${TIMING_REPO}
    # ---- Create the timing file if it does not exist
    if [[ ! -f timing/y1-nozzle-timings.yaml ]]; then 
        touch timing/y1-nozzle-timings.yaml
        (cd timing && git add y1-nozzle-timings.yaml)
    fi
    # ---- Update the timing file with the current test data
    cat nozzle_timings.yaml >> timing/y1-nozzle-timings.yaml
    # ---- Commit the new data to the repo
    (cd timing && git commit -am "Automatic commit: ${TIMING_HOST} ${TIMING_DATE}" && git push)
else
    printf "Timing run did not produce the expected sqlite file: nozzle-timing.sqlite-rank0\n"
    exit 1
fi
