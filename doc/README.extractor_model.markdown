These are some rouch instructions for regenerating the extractor model.

The instructions assume that the file `/home/dlarochelle/R/machine_learning/training_download_information.dat` contains a [Perl Storable](http://perldoc.perl.org/Storable.html) representation of download objects.

Steps:

```
./script/run_with_carton.sh ./script/mediawords_extractor_test_to_features.pl --file=/home/dlarochelle/R/machine_learning/training_download_information.dat  >  features_regen/all_training_downloads_features.dat
time nice ./script/run_with_carton.sh script/crf_create_model.pl features_regen/all_training_downloads_features.dat 500
cp features_regen/all_training_downloads_featuresModel.txt lib/MediaWords/Util/models/crf_extractor_model
```

Run the following and verify that the mode is sane:
```
MEDIACLOUD_IGNORE_DB_SCHEMA_VERSION=1 time ./script/run_with_carton.sh ./script/mediawords_test_extractor.pl --download_data_load_file  ~/mc/mediacloud/trunk/test_test_extractor_downloads.dat
```

(The non_ignorable line in the output of the above command should be at least 97% correct. However, do not use that number to report the accuracy of the model because it involves testing and training on the same data.)
