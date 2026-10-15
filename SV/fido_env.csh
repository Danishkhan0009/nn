#==============================================================================
# FIDO V3 (WITCHER) SV kit - interactive tcsh/csh setup (optional)
#   csh
#   source /home/install/cshrc              <- Cadence set-up, every new terminal
#   source /home/testam/WITCHER/SV/fido_env.csh
# The run_*.sh scripts set the Xcelium path themselves; this file is only for
# running xrun / simvision by hand in a tcsh terminal.
#==============================================================================
setenv XCELIUM_HOME /home/install/XCELIUM2209
setenv PATH ${XCELIUM_HOME}/tools/bin:${PATH}
setenv FIDO_SV_ROOT /home/testam/WITCHER/SV
rehash
echo "Xcelium: `which xrun`"
