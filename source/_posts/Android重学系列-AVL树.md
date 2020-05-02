---
title: Android重学系列 AVL树
top: false
cover: false
date: 2019-03-22 22:58:00
img:
tag:
description:
author: yjy239
summary:
tags:
- 算法
---
# 背景
接着上面那个二叉搜索树来讲。有思考过二叉搜索树最差的搜索时间复杂度吗？最差的时候，二叉搜索树插入的数据刚好是一条直线，这样时间复杂度就蜕变和链表没什么区别（就是从O(logN)蜕变到O(n)级别）。因此AVL树因此诞生了。

如下图所示：
![avl平衡树诞生的原因.png](/images/avl平衡树诞生的原因.png)


# 正文

AVL树有什么概念呢？在二叉搜索树之上，我们为了保证整个树都有左右节点，尽量做到每个大小的节点都均匀分布，也就在二叉搜索上添加一个约束：

> 每个结点的左右子树的高度之差的绝对值（平衡因子）最多为1。

我们究竟怎么样才能让这个树保证，每个节点的左右树高度差小于等于1呢？可以想象到的方案是，每一次加入一个新的节点，或者删除一个节点（也就是破坏平衡），通过不改变二叉搜索树的基本原则下，对节点进行调整，最终达到每个结点的左右子树的高度之差的绝对值（平衡因子）最多为1的效果。

下面是AVL树算法给出的调整方案。

首先是两个基础旋转方案，左旋以及右旋：
#### 左旋

![左旋.png](/images/左旋.png)



从上图可以看到，此时b的左右子树高度明显不平衡。整个树往右边长了，导致了节点分布不均。所以我们需要人为的调整。

很浅显的道理，右边多了，就把右边的部分修建下来，移动到左边去。就像修建树木一样。为了保证二叉搜索树的结构不被破坏，我们需要A右边的节点作为根移动到A的位置，A比B小就移动到左边，这样二叉树又一次平衡起来了。

这样不就遗失掉一些节点吗？所以我们需要去看看A占掉的节点位置，我们要移动到A下面，此时B的左节点还是比A大的，所以，C就移动到了A的右侧。


#### 右旋
![右旋.png](/images/右旋.png)

和上面相同的道理。此时左边的树更长了，为了树的平衡，我们向右旋转，这个树，B成为了根，A就到了B的右侧，B的右节点就到了A的左侧。

##### 小总结
记住，往那边旋转，哪边的子树不需要变动。而相反方向的节点，由于被原来的根代替了，遗留下来的子树，所以就去到了原来根下面找合适的位置，左旋加到右边，右旋加到左边。

这样总结下来还是看起来挺平衡的。


但是也别太乐观，光是这两种旋转还是不能处理一些长得歪歪扭扭的树，有时候光是一种旋转是没有办法处理。可能需要两种旋转一起处理，才能完成树的平衡。

比如说这种情况：
#### 左右旋

![左右旋.png](/images/左右旋.png)



当出现原本应该往左边长的树，却一直往右边长的树。我们尝试着单次旋转如上图的第一步。无论是向左旋，还是向右旋。你会发现都不平衡。比如说试试右旋，你会发现B右边的节点已经被C占有，A无法处理。

因此，在这种情况下，我们可以对着该节点的子树进行一次左旋，来达到可以一次旋转处理的情况。

#### 右左旋

![右左旋.png](/images/右左旋.png)


右左旋的思路同上，因为做一次旋转，我们无法平衡树，所以先做一次旋转达到能够处理的情况。如上图所示，树本应该向右边生长，而此时B节点右边没长，反而左边一直长。所以我们要处理的，就是把b右旋之后，再把a左旋，此时树就平横了。

### AVL树算法实现

关键的四个操作已经明白了，我们这一次也是实现增删查改。

我们一样还是构造出树节点的基本类。
```
template <class K,class V>
class TreeNode{
public:
    TreeNode *left = NULL;
    TreeNode *right = NULL;
    K key;
    V value;

    int height;

    TreeNode(TreeNode* node){
        this->left = node->left;
        this->right = node->right;
        this->key = node->key;
        this->value = node->value;
        this->height = node->height;
    }

    TreeNode(K key,V value):height(1){
        this->left = NULL;
        this->right = NULL;
        this->key = key;
        this->value = value;

    }

};

```

你会发现比起二叉搜索树，多了一个height属性，为的就是每一次添加之后，判断高度是否最大不超过1，超过则进行旋转处理。

接下来写一个，获取子树高度的方法。
```
    int getHeight(TreeNode *node){
        return node ? node->height : 0;
    }
```

解析来，我们来写写左旋和右旋的基础方法：
##### 左旋
```
//对着根节点左旋
    TreeNode<K,V>* L_Rotation(TreeNode<K,V> *node){
        //右节点挪动到根部位置
        TreeNode<K,V> *result_root = node->right;
        //移动到根的时候，此时之前的根，变成了左节点
        //记住往哪里旋转哪里不变，变化的是相反方向的节点

        //此时node 的 right不再是 变化后的根节点了，而是替换成了根后面的左节点
        node->right = result_root->left;
        //根节点变成右节点
        result_root->left = node;

        //处理完根节点之后，记住要处理一下高度
        //这边的高度是获取子树最大高度，已经更新当前节点高度
        node->height = max(getHeight(node->left)
                ,getHeight(node->right)) + 1;

        result_root->height = max(getHeight(result_root->left),getHeight(result_root->right)) + 1;

        return result_root;
    }
```

#### 右旋
```
//对着根节点右旋
    TreeNode<K,V>* R_Roation(TreeNode<K,V> *node){
        //左孩子移动到根部
        TreeNode<K,V> *result_root = node->left;
        //此时原来左孩子的右侧已经是根了，原来的左孩子根部比此时的根小，则放到右侧
        node->left = result_root->right;

        //原来的根节点变成了右孩子
        result_root->right = node;


        node->height = max(getHeight(node->left)
                ,getHeight(node->right)) + 1;

        result_root->height = max(getHeight(result_root->left),getHeight(result_root->right)) + 1;

        return result_root;
    }
```

##### 左右旋
根据左右旋的图，发现这个树最好应该往左边生长的，但是却往右边长，长歪了。所以要去找左节点进行左旋之后，再对根节点右旋。
```
//先左旋，后右旋
    TreeNode<K,V> *LR_Roation(TreeNode *node){
        //本应该这个树是往左边生长的，但是却往右边一直长，所以先获取左边孩子
        node->left = L_Rotation(node->left);
        return R_Roation(node);
    }
```

#####  右左旋
```
    TreeNode<K,V> *RL_Roation(TreeNode *node){
        node->right = R_Roation(node->right);
        return L_Rotation(node);
    }
```


### AVL 树的插入
```
    TreeNode *addNode(TreeNode *node,K key,V value){
        if(!node){
            count++;
            return new TreeNode<K,V>(key,value);
        }


        if(key < node->key){
            node->left = addNode(node->left,key,value);
        } else if(key > node->key){
            node->right = addNode(node->right,key,value);
        } else{
            node->value = value;
        }


        return node;
    }

```

实际上AVL树是早二叉搜索树上发展而来的。所以把上文的插入节点的方法拷贝过来。在插入之后，我们需要做适当的调整。

根据上面的逻辑，我们继续思考下去。那是结构十分简单的AVL树，但是当我们扩展到高度更高的树的时候，我们就要对每一层都要处理一次。换到代码逻辑中就是在一层都添加一次高度判断，是否需要旋转。


我们再进一步的思考下去，是不是每一次我们都要判断是左旋还是右旋，还是左右旋呢？

实际上，根据我在上面讲的。我们需要注意生长方向，如果这棵树是往左边找节点添加的，说明树的生长方向是往左边的。

也就是说，我们只需要判断右旋还是左右旋即可。因为左边的节点已经足够多了，不可能左旋，导致AVL树更加歪，而应该右旋。再继续深度思考下去，那假如从左边找却发现了右边的树更高，那说明我们期待本应该一直左长的树能够一次解决，却长得更歪了，只能做一次左旋再右旋.

那么相同的道理能换算到右边去。

```
    TreeNode<K,V>* addNode(TreeNode<K,V> *node,K key,V value){
        if(!node){
            count++;
            return new TreeNode<K,V>(key,value);
        }

        if(key < node->key){
            node->left = addNode(node->left,key,value);
            if(getHeight(node->left) - getHeight(node->right) == 2){
                if(getHeight(node->left->left) >= getHeight(node->left->right)){
                    //说明树往左边长，能够正常的单次旋转解决
                    node = R_Roation(node);
                } else if(getHeight(node->left->left) < getHeight(node->left->right)){
                    //否则是左边的树长歪了，需要先左旋再右旋。
                    node = LR_Roation(node);
                }
            }

        } else if(key > node->key){
            node->right = addNode(node->right,key,value);
            if(getHeight(node->right) - getHeight(node->left) == 2){
                if(getHeight(node->right->right) > getHeight(node->right->left)){
                    //说明树往右边长
                    node = L_Rotation(node);
                } else if(getHeight(node->right->right) < getHeight(node->right->left)){
                    node = RL_Roation(node);
                }
            }

        } else{
            node->value = value;
        }

        node->height = max(getHeight(node->left),getHeight(node->right)) + 1;
        return node;
    }


    void put(K key,V value){
        root = addNode(root,key,value);
    }
```

写一个前序遍历测试一下：
```
//前序遍历,先根，后左，最后右
    void levelTravel(void (*fun)(K, V)){
        if(!root){
            return;
        }


        TreeNode<K,V> *node = root;
        queue<TreeNode<K,V>*> nodes;

        nodes.push(root);

        while (!nodes.empty()){
            TreeNode<K,V> *p = nodes.front();
            fun(p->key,p->value);
            nodes.pop();

            if(p->left){
                nodes.push(p->left);
            }

            if(p->right){
                nodes.push(p->right);
            }
        }
    }
```

```
 AVL<int,int> *avl = new AVL<int,int>();

    avl->put(3,3);
    avl->put(1,1);
    avl->put(2,2);
    avl->put(4,4);
    avl->put(5,5);
    avl->put(6,6);
    avl->put(7,7);
    avl->put(10,10);
    avl->put(9,9);
    avl->put(8,8);

    avl->levelTravel(visit);

```

![avl测试结果.png](/images/avl测试结果.png)

让我们推导一边流程，看看结果是否正确。
先分批分析，先看看从3开始一路加到5如何。

![avl树添加节点分步解析1.png](/images/avl树添加节点分步解析1.png)

我们接着看看从6-10的过程
![avl树节点插入分解步骤2.png](/images/avl树节点插入分解步骤2.png)

根据先序遍历，打印顺序是4，2，7，1，3，6，9，5，8，10
顺序正确，测试完毕。

### AVL树的删除
avl 树的删除比起插入，稍微有点复杂。但是扣紧定义，来实际上并不困难。

实际上我们要考虑的事情有一下几点：
1.删除叶子节点，也就是没有任何子节点。
2.只有一个节点
3.有两个节点的时候。

这个时候的思考方式和二叉搜索树十分相似。在删除节点的时候，只需要直接删除，但是还是要注意平衡。删除只有一个节点，就没有必要去找前驱后继，毕竟此时树的生长方向只有一个。在删除两个节点的时候则要考虑前驱后继的问题，因为树往两个方向生长，想要保证二叉搜索树的性质，只能两方面的考虑。

最后记得，把节点调整回来。

```
    TreeNode<K,V>* removeNode(TreeNode<K,V> *node,K key){
        if(!node){
            count--;
            return NULL;
        }


        if(key < node->key){
            node->left = removeNode(node->left,key);
            if(getHeight(node->right) - getHeight(node->left) == 2){
                if(getHeight(node->right->right) > getHeight(node->right->left)){
                    //说明树往右边长
                    node = L_Rotation(node);
                } else if(getHeight(node->right->right) < getHeight(node->right->left)){
                    node = RL_Roation(node);
                }
            }

        } else if(key > node->key){
            node->right = removeNode(node->right,key);

            if(getHeight(node->left) - getHeight(node->right) == 2){
                if(getHeight(node->left->left) >= getHeight(node->left->right)){
                    //说明树往左边长，能够正常的单次旋转解决
                    node = R_Roation(node);
                } else if(getHeight(node->left->left) < getHeight(node->left->right)){
                    //否则是左边的树长歪了，需要先左旋再右旋。
                    node = LR_Roation(node);
                }
            }
        } else{
            //按照情况区分
            //1.左右无节点
            //2。左右有节点
            //3。只有左或者右节点
            count--;
            if(!node->left&&!node->right){
                delete(node);
                return NULL;
            } else if(node->left && node->right){
                //左右都有节点
                //需要特殊处理,找到是左边高，还是右边高
                if(getHeight(node->left) > getHeight(node->right)){
                    //这种做法是为了尽可能的避免调整过多的旋转，
                    // 所以我们将会拿出多出那一块的后继或者前驱补充上去

                    //此时是左边高，我们从左树获取最大值
                    TreeNode<K,V> *max = new TreeNode<K,V>(maxium(node->left));
                    //重新设置值
                    max->left = removeNode(node->left,max->key);
                    //原来那个还存在

                    max->right = node->right;

                    delete(node);

                    node = max;

                } else{

                    //此时是右边高，我们从右树获取最小值
                    TreeNode<K,V> *min = new TreeNode<K,V>(minium(node->right));
                    //重新设置值
                    min->right = removeNode(node->right,min->key);
                    //原来那个还存在

                    min->left = node->left;

                    delete(node);

                    node = min;
                }



            } else if(node->left){
                TreeNode<K,V> *left = node->left;
                delete(node);
                return left;

            } else{
                TreeNode<K,V> *right = node->right;
                delete(node);
                return right;

            }
        }

        return node;
    }

    void remove(K key){
        root = removeNode(root,key);
    }
```

此时，我们需要考虑的更多的是，我们实际上我们在往左边还是右边寻找节点删除的时候，必定会破坏平衡。当我们删除的左边节点时候，必定导致右边多出一个高度，此时我们只需要考虑左旋和右左旋。而不需要考虑右旋和左右旋。同理换到另一个方向去。

测试：
```
    AVL<int,int> *avl = new AVL<int,int>();

    avl->put(3,3);
    avl->put(1,1);
    avl->put(2,2);
    avl->put(4,4);
    avl->put(5,5);
    avl->put(6,6);
    avl->put(7,7);
    avl->put(10,10);
    avl->put(9,9);
    avl->put(8,8);

    avl->remove(8);
    avl->remove(4);
    avl->remove(6);
    avl->remove(10);
    avl->levelTravel(visit);
```

选择几个特殊的节点，测试结果：

![测试结果.png](/images/avl完成测试结果.png)

再一次分解一下动作看看。

![avl树删除节点分解步骤.png](/images/avl树删除节点分解步骤.png)

而查和搜索二叉树，没有任何区别。

至此，avl树的增删查改，已经全部梳理一遍。


### 后话

接下来，就是红黑树了。avl树属于比较好理解的树，并不复杂，只要理清楚思路就能盲敲出来。




