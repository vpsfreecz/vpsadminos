source $stdenv/setup

mkdir -p $out

rm env-vars
mkdir config rootfs

cp $metaYml ./metadata.yml
cp $ctYml ./config/container.yml
cp $userYml ./config/user.yml
cp $groupYml ./config/group.yml
cp -prd $rootFs/tarball/*.tar.gz ./rootfs/base.tar.gz

tar --sort=name --mtime='@1' --owner=0 --group=0 --numeric-owner -c * > $out/$fileName.tar
