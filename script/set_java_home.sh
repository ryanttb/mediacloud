#!/bin/bash
#
# Try to guess path to where Java is installed and set the Bash variable accordingly
#

if [ `uname` == 'Darwin' ]; then

    # Mac OS X
    POSSIBLE_JDK_PATH=/System/Library/Frameworks/JavaVM.framework/

    if     [[ -d "$POSSIBLE_JDK_PATH"
        &&    -f "$POSSIBLE_JDK_PATH/Commands/javac"
        &&    -f "$POSSIBLE_JDK_PATH/Headers/jni.h" 
        &&    -f "$POSSIBLE_JDK_PATH/Libraries/libjvm.dylib" ]]; then

        JAVA_HOME="$POSSIBLE_JDK_PATH"

    else
        echo "Proper Java deployment was not found in $POSSIBLE_JDK_PATH."
        echo "Please download and install Java for OS X Developer Package from"
        echo "https://developer.apple.com/downloads/ or via the Software Update."
        exit 1
    fi

else

    # Ubuntu
    declare -a POSSIBLE_JDK_PATHS=(
        /usr/lib/jvm/java-7-openjdk-amd64/  # newer Ubuntu
        /usr/lib/jvm/java-6-sun             # older Ubuntu
    )

    for path in ${POSSIBLE_JDK_PATHS[@]}; do
        if     [[ -d "$path"
            &&    -f "$path/bin/javac"
            &&    -f "$path/include/jni.h" ]] ; then
            
            JAVA_HOME="$path"
        fi
    done
    if [ -z "$JAVA_HOME" ]; then
        echo "Proper Java deployment was not found anywhere."
        echo "Please download and install Java for OS X Developer Package by running:"
        echo "    apt-get install openjdk-7-jdk"
        exit 1
    fi

fi