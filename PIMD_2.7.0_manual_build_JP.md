# PIMD 2.7.0 + QE 6.3 + n2p2（＋AENET オプション）手動ビルド手順書

この文書では、提供された自動スクリプトを使わずに、**PIMD 2.7.0** を **Quantum ESPRESSO (QE)** および **n2p2** と連携させて手動でコンパイルする手順を説明します。  
オプションとして **AENET** を組み込む方法も含みます。

---

## 0. 前提条件

- `pimd.2.7.0.r2.tar.gz` を入手済みであること。
- ビルド用の作業ディレクトリを `WORK_DIR` とする。
- 環境は Linux (x86_64)、Intel oneAPI コンパイラ（`ifx`, `mpiifx`, `icx`, `mpiicx`）を使用。
- n2p2 と QE 6.3 の統合ビルドを行う。
- AENET を利用する場合は、別途ソースまたはアーカイブを用意。

---

## 1. 作業ディレクトリの準備

```bash
export WORK_DIR=$HOME/pimd-manual
mkdir -p $WORK_DIR
cd $WORK_DIR

# ここに PIMD アーカイブを配置しておく
ls pimd.2.7.0.r2.tar.gz
```

展開：

```bash
gzip -dk pimd.2.7.0.r2.tar.gz
tar -xf pimd.2.7.0.r2.tar
ls
```

トップディレクトリ名（例: `pimd.2.7.0.r2`）を確認して設定：

```bash
export SRC_DIR=$WORK_DIR/pimd.2.7.0.r2
```

---

## 2. Intel oneAPI 環境の読み込み

```bash
source /opt/intel/oneapi/setvars.sh --force >/dev/null 2>&1 || true
```

確認：

```bash
command -v ifx mpiifx icx mpiicx
```

LLVM ツールを優先する場合：

```bash
export AR=$(command -v llvm-ar || true)
export RANLIB=$(command -v llvm-ranlib || true)
export ARFLAGS=rcs
```

---

## 3. コンパイラ設定

```bash
export CC=mpiicx
export CXX=mpiicpx
export FC=mpiifx
export CC_SERIAL=icx
export FC_SERIAL=ifx
export MPIF90="mpiifx -fc=ifx"
export MPIF77=mpiifx
export CFLAGS="${CFLAGS:-} -include math.h"
```

> QE が `ifort` を要求する場合、以下のようなラッパを作成：  
> ```bash
> mkdir -p $WORK_DIR/wrappers
> echo -e '#!/usr/bin/env bash\nexec ifx "$@"' > $WORK_DIR/wrappers/ifort
> echo -e '#!/usr/bin/env bash\nexec mpiifx "$@"' > $WORK_DIR/wrappers/mpiifort
> chmod +x $WORK_DIR/wrappers/*
> export PATH=$WORK_DIR/wrappers:$PATH
> ```

---

## 4. （任意）AENET の組み込み

### 4.1 ソース配置

```bash
export AENET_SRC=/path/to/aenet-2.0.3
export AENET_TAR=/path/to/aenet-2.0.3.tar.bz2
export AENET_STAGE=$SRC_DIR/lib/aenet

mkdir -p $AENET_STAGE
rm -rf $AENET_STAGE/src $AENET_STAGE/lib $AENET_STAGE/src_modified
```

ソースまたはアーカイブから配置：

```bash
if [[ -d $AENET_SRC/src && -d $AENET_SRC/lib ]]; then
  cp -a $AENET_SRC/src $AENET_STAGE/
  cp -a $AENET_SRC/lib $AENET_STAGE/
else
  tar -xf $AENET_TAR -C $AENET_STAGE
fi
```

Lbfgsb 展開：

```bash
if [[ -f $AENET_STAGE/lib/Lbfgsb.3.0.tar.gz && ! -d $AENET_STAGE/lib/Lbfgsb.3.0 ]]; then
  (cd $AENET_STAGE/lib && tar -xzf Lbfgsb.3.0.tar.gz)
fi
```

パッチ適用：

```bash
chmod +x $AENET_STAGE/apply_patch.sh
(cd $AENET_STAGE && ./apply_patch.sh)
```

### 4.2 ビルド

```bash
make -C $AENET_STAGE/lib clean || true
make -C $AENET_STAGE/lib liblbfgsb.a

MK=$AENET_STAGE/src_modified/makefiles/Makefile.ifort_mpi
make -C $AENET_STAGE/src_modified -f $MK clean || true
make -C $AENET_STAGE/src_modified -f $MK lib

mkdir -p $SRC_DIR/lib
cp $AENET_STAGE/lib/liblbfgsb.a $SRC_DIR/lib/
cp $AENET_STAGE/src_modified/libaenet.a $SRC_DIR/lib/
```

---

## 5. n2p2 の準備とビルド

```bash
export N2P2_ROOT=$SRC_DIR/lib/n2p2
chmod +x $N2P2_ROOT/getandapply_patch.sh
(cd $N2P2_ROOT && ./getandapply_patch.sh)
```

ライブラリのビルド：

```bash
export N2P2_MOD=$N2P2_ROOT/n2p2-2.2.0.modified

for d in libnnp libnnptrain libnnpif; do
  make -C $N2P2_MOD/src/$d clean || true
  make -C $N2P2_MOD/src/$d COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx \
    PROJECT_CFLAGS="-O3 -march=native -std=c++11"
done

mkdir -p $SRC_DIR/lib
cp $N2P2_MOD/lib/libnnp*.a $SRC_DIR/lib/
```

---

## 6. Quantum ESPRESSO 6.3 の配置

```bash
mkdir -p $SRC_DIR/lib/qe
cd $SRC_DIR/lib/qe

# オンラインの場合
curl -L -o qe-6.3.zip https://github.com/QEF/q-e/archive/refs/tags/qe-6.3.zip

# オフラインの場合
# 事前に取得済みファイルをこの場所にコピー
```

---

## 7. CMake 設定

```bash
export BUILD_DIR=$WORK_DIR/build
rm -rf $BUILD_DIR && mkdir -p $BUILD_DIR

cmake -S $SRC_DIR -B $BUILD_DIR \
  -DMKLUSE=ON -DQE=ON -DQEVERSION=6.3 \
  -DQEFILES=$SRC_DIR/lib/qe/qe-6.3.zip \
  -DN2P2=ON \
  -DCMAKE_BUILD_TYPE=RelWithDebInfo \
  -DCMAKE_C_COMPILER=mpiicx \
  -DCMAKE_CXX_COMPILER=mpiicpx \
  -DCMAKE_Fortran_COMPILER=mpiifx
```

AENET 組み込みを有効にする場合：

```bash
cmake -DAENET=ON ...
```

---

## 8. ビルド

```bash
cmake --build $BUILD_DIR -- -j$(nproc)
```

成果物を確認：

```bash
ls -1 $BUILD_DIR/pimd*.x $BUILD_DIR/polymers*.x 2>/dev/null
mkdir -p $BUILD_DIR/bin
cp $BUILD_DIR/pimd*.x $BUILD_DIR/polymers*.x $BUILD_DIR/bin/ 2>/dev/null || true
```

---

## 9. SiO₂（QE連成例）のテスト実行

```bash
EXAMPLE_DIR=$SRC_DIR/examples/SiO2/qe_md
RUN_DIR=$BUILD_DIR/run/SiO2_qe_md
mkdir -p $RUN_DIR
cp -a $EXAMPLE_DIR/. $RUN_DIR/
cd $RUN_DIR

mpirun -np 2 $BUILD_DIR/bin/pimd.mpi.x < input.dat | tee run.log
```

出力ファイル（例）：`standard.out`, `rdf.out`, `final.xyz`, `final.poscar`

---

## 10. トラブルシューティング

| 問題 | 対応 |
|------|------|
| ifort が見つからない | ラッパスクリプトを利用（§3参照） |
| MKL/mpi リンクエラー | oneAPI の環境を再読込し、CMake を再実行 |
| llvm-ar が無い | GNU binutils の ar/ranlib を使用 |
| QE 初期化時に segfault | `-check all -traceback` 付きで再ビルド |
| AENET makefile が ifort 固定 | `Makefile.options` に変更して ifx 対応 |

---

## 11. クイックリファレンス

```bash
source /opt/intel/oneapi/setvars.sh
export CC=mpiicx CXX=mpiicpx FC=mpiifx
gzip -dk pimd.2.7.0.r2.tar.gz && tar -xf pimd.2.7.0.r2.tar
export SRC_DIR=$WORK_DIR/pimd.2.7.0.r2
chmod +x $SRC_DIR/lib/n2p2/getandapply_patch.sh
(cd $SRC_DIR/lib/n2p2 && ./getandapply_patch.sh)
make -C $SRC_DIR/lib/n2p2/n2p2-2.2.0.modified/src/libnnp COMP=intel PROJECT_CC=icpx PROJECT_MPICC=mpiicx PROJECT_CFLAGS="-O3 -march=native -std=c++11"
mkdir -p $SRC_DIR/lib/qe && curl -L -o $SRC_DIR/lib/qe/qe-6.3.zip https://github.com/QEF/q-e/archive/refs/tags/qe-6.3.zip
mkdir -p $WORK_DIR/build && cmake -S $SRC_DIR -B $WORK_DIR/build -DMKLUSE=ON -DQE=ON -DQEVERSION=6.3 -DQEFILES=$SRC_DIR/lib/qe/qe-6.3.zip -DN2P2=ON -DCMAKE_BUILD_TYPE=RelWithDebInfo -DCMAKE_C_COMPILER=mpiicx -DCMAKE_CXX_COMPILER=mpiicpx -DCMAKE_Fortran_COMPILER=mpiifx
cmake --build $WORK_DIR/build -- -j$(nproc)
```

---

**以上。**
