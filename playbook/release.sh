set -e


PY36=/data/apps/jenkins/.pyenv/versions/3.6.2/bin/python3.6
VENV_HOME=$WORKSPACE/.venv
if [ ! -d $VENV_HOME ]; then
    $PY36 -m venv $VENV_HOME
fi

. $VENV_HOME/bin/activate

pip install -U ansible 

ansible-playbook deploy-prod.yml